open Firebase

type stats = {
  totalGames: int,
  totalRedWins: int,
  totalBlueWins: int,
  totalAbsoluteWins: int,
}

let statsSchema = Schema.object(s => {
  totalGames: s.fieldOr("games", Schema.int, 0),
  totalRedWins: s.fieldOr("redWins", Schema.int, 0),
  totalBlueWins: s.fieldOr("blueWins", Schema.int, 0),
  totalAbsoluteWins: s.fieldOr("absoluteWins", Schema.int, 0),
})

let empty: stats = {
  totalGames: 0,
  totalRedWins: 0,
  totalBlueWins: 0,
  totalAbsoluteWins: 0,
}

let bucket = "stats"

let fetchStats = async () => {
  let stats = await Firebase.Database.refPath(Database.database, bucket)->Firebase.Database.get
  switch stats->Firebase.Database.Snapshot.val->Js.toOption {
  | Some(stats) =>
    switch Schema.parseWith(stats, statsSchema) {
    | Ok(stats) => Some(stats)
    | Error(error) => {
        Console.error(error)
        None
      }
    }
  | None => None
  }
}

let useStats = () => {
  let (stats, setStats) = React.useState(_ => empty)
  let statsRef = Firebase.Database.refPath(Database.database, bucket)
  React.useEffect(() => {
    let unsubscribe = Firebase.Database.onValue(
      statsRef,
      snapshot => {
        switch snapshot->Firebase.Database.Snapshot.val->Js.toOption {
        | Some(stats) =>
          switch Schema.parseWith(stats, statsSchema) {
          | Ok(stats) => setStats(_ => stats)
          | Error(error) => Console.error(error)
          }
        | None => ()
        }
      },
      (),
    )

    Some(unsubscribe)
  }, [])

  stats
}

let updateStats = async (redScore, blueScore) => {
  let blueWin = Rules.isBlueWin(redScore, blueScore)
  let redWin = Rules.isRedWin(redScore, blueScore)
  let isAbsolute = Rules.isAbsolute(redScore, blueScore)
  let statsRef = Firebase.Database.refPath(Database.database, bucket)
  Firebase.Database.runTransaction(statsRef, data => {
    switch data->Schema.parseWith(statsSchema) {
    | Ok(data) => {
        let newData = Schema.serializeOrRaiseWith(
          {
            totalGames: data.totalGames + 1,
            totalRedWins: data.totalRedWins + (redWin ? 1 : 0),
            totalBlueWins: data.totalBlueWins + (blueWin ? 1 : 0),
            totalAbsoluteWins: data.totalAbsoluteWins + (isAbsolute ? 1 : 0),
          },
          statsSchema,
        )
        newData
      }
    | Error(_) => panic("Failed parsing stats")
    }
  })
}

let writeStats = async stats => {
  let statsRef = Firebase.Database.refPath(Database.database, bucket)
  let data = switch stats->Schema.serializeWith(statsSchema) {
  | Ok(data) => {
      Js.log2("Log", data)
      data
    }
  | Error(_) => panic("Could not serialize stats")
  }
  await Firebase.Database.set(statsRef, data)
}

let recalculateStats = async () => {
  let games = await Games.fetchAllGames()
  let players = await Players.fetchAllPlayers()

  let playerKeys = Dict.keysToArray(players)
  Array.forEach(playerKeys, key => {
    let player = Dict.get(players, key)->Option.getExn
    Dict.set(
      players,
      key,
      {
        ...player,
        elo: 1000.0,
        lastEloChange: 0.0,
        lastGames: [],
      },
    )
  })

  let stats: stats = empty

  let stats = games->Array.reduce(stats, (stats, game) => {
    let blueWin = Rules.isBlueWin(game.redScore, game.blueScore)
    let redWin = Rules.isRedWin(game.redScore, game.blueScore)
    let isAbsolute = Rules.isAbsolute(game.redScore, game.blueScore)

    let redPlayers = game.redTeam->Array.map(key => Dict.get(players, key)->Option.getExn)
    let bluePlayers = game.blueTeam->Array.map(key => Dict.get(players, key)->Option.getExn)

    let (bluePlayers, redPlayers, _) = switch blueWin {
    | true => Elo.calculateScore(bluePlayers, redPlayers)
    | false => {
        let (red, blue, points) = Elo.calculateScore(redPlayers, bluePlayers)
        (blue, red, points)
      }
    }
    Array.forEach(bluePlayers, player => {
      let lastGames = Players.getLastGames(player.lastGames, blueWin)
      Dict.set(
        players,
        player.key,
        {
          ...player,
          lastGames,
        },
      )
    })
    Array.forEach(redPlayers, player => {
      let lastGames = Players.getLastGames(player.lastGames, redWin)
      Dict.set(
        players,
        player.key,
        {
          ...player,
          lastGames,
        },
      )
    })

    // Js.log(points)

    {
      totalGames: stats.totalGames + 1,
      totalRedWins: stats.totalRedWins + (redWin ? 1 : 0),
      totalBlueWins: stats.totalBlueWins + (blueWin ? 1 : 0),
      totalAbsoluteWins: stats.totalAbsoluteWins + (isAbsolute ? 1 : 0),
    }
  })

  Js.log(stats)
  Js.log(players)

  let _ = await Promise.all(
    Array.map(playerKeys, key => {
      let player = Dict.get(players, key)->Option.getExn
      Players.writePlayer(player)
    }),
  )

  await writeStats(stats)

  stats
}
