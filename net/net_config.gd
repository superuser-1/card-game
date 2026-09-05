class_name NetConfig
extends RefCounted
## Shared network constants used by both server and client.

const DEFAULT_PORT := 8910
const DEFAULT_ADDRESS := "127.0.0.1"

## Players per match (the rules engine is strictly 2-player).
const MAX_PLAYERS := 2

## ENet peer cap for the whole server process — many concurrent matches plus
## players sitting in menus / the matchmaking queue.
const MAX_SERVER_PEERS := 256
