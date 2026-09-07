local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

local HEARTBEAT_INTERVAL = 20
local REGISTRY_TTL = 90
local ACTIVE_WINDOW = 60
local MAX_PICK_SCAN = 200

export type TeleportArgs = {
	plrList: { Player },
	teleportData: {}?,
	targetServer: ("standard" | "reserved")?,
	reservedServerAccessCode: string?,
}

export type ReservedServerInfo = {
	accessCode: string,
	privateServerId: string,
	jobId: string,
	playerCount: number,
	updatedAt: number,
	liveTime: number,
}

type PoolRegistries = {
	registry: MemoryStoreSortedMap,
	liveTimeRegistry: MemoryStoreSortedMap,
}

local initialized = false
local registriesByPool: { [string]: PoolRegistries } = {}

local function getRegistries(poolName: string): PoolRegistries
	local regs = registriesByPool[poolName]
	if not regs then
		regs = {
			registry = MemoryStoreService:GetSortedMap(poolName .. "_ReservedServerRegistryV1"),
			liveTimeRegistry = MemoryStoreService:GetSortedMap(poolName .. "_ReservedServerLiveTimeRegistryV1"),
		}
		registriesByPool[poolName] = regs
	end
	return regs
end

local function startPool(poolName: string, accessCode: string?)
	local regs = getRegistries(poolName)

	local function writeHeartbeat()
		local info: ReservedServerInfo = {
			accessCode = accessCode :: string,
			privateServerId = game.PrivateServerId,
			jobId = game.JobId,
			playerCount = #Players:GetPlayers(),
			updatedAt = os.time(),
			liveTime = math.floor(workspace.DistributedGameTime),
		}
		local ok1, err1 = pcall(regs.registry.SetAsync, regs.registry, game.JobId, info, REGISTRY_TTL, info.updatedAt)
		if not ok1 then
			warn("[ServerTeleport] heartbeat write failed (registry): " .. tostring(err1))
		end
		local ok2, err2 =
			pcall(regs.liveTimeRegistry.SetAsync, regs.liveTimeRegistry, game.JobId, info, REGISTRY_TTL, info.liveTime)
		if not ok2 then
			warn("[ServerTeleport] heartbeat write failed (liveTimeRegistry): " .. tostring(err2))
		end
	end

	game:BindToClose(function()
		local ok1, err1 = pcall(regs.registry.RemoveAsync, regs.registry, game.JobId)
		if not ok1 then
			warn("[ServerTeleport] deregister failed (registry): " .. tostring(err1))
		end
		local ok2, err2 = pcall(regs.liveTimeRegistry.RemoveAsync, regs.liveTimeRegistry, game.JobId)
		if not ok2 then
			warn("[ServerTeleport] deregister failed (liveTimeRegistry): " .. tostring(err2))
		end
	end)

	while true do
		writeHeartbeat()
		task.wait(HEARTBEAT_INTERVAL)
	end
end

local server = {}

function server.init(studioSetServer: string?)
	if initialized then
		error("[ServerTeleport] init() called more than once")
	end
	initialized = true

	task.spawn(function()
		local serverType: string
		local accessCode: string? = nil

		if type(studioSetServer) == "string" and studioSetServer ~= "" then
			serverType = studioSetServer
		elseif game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0 then
			local plr = Players:FindFirstChildWhichIsA("Player") or Players.PlayerAdded:Wait()
			local teleportData = plr:GetJoinData().TeleportData
			local poolName = type(teleportData) == "table" and teleportData.__poolName or nil
			if type(poolName) ~= "string" or poolName == "" then
				error("[ServerTeleport] reserved server booted without __poolName in TeleportData")
			end
			serverType = poolName
			accessCode = teleportData.__reservedServerAccessCode
		else
			serverType = "standard"
		end

		script:SetAttribute("serverType", serverType)

		if serverType ~= "standard" then
			startPool(serverType, accessCode)
		end
	end)
end

function server.teleport(poolName: string, args: TeleportArgs)
	if not initialized then
		error("[ServerTeleport] teleport() called before init()")
	end

	local teleportData = table.clone(args.teleportData or {})
	teleportData.__poolName = poolName

	local accessCode = args.reservedServerAccessCode
	local targetServer = args.targetServer or "reserved"
	if accessCode == nil and targetServer == "reserved" then
		local ok, code = pcall(TeleportService.ReserveServerAsync, TeleportService, game.PlaceId)
		if not ok or type(code) ~= "string" or code == "" then
			warn("[ServerTeleport] failed to reserve server: " .. tostring(code))
			return
		end
		accessCode = code
	end

	local teleportOptions = Instance.new("TeleportOptions")
	if type(accessCode) == "string" and accessCode ~= "" then
		teleportData.__reservedServerAccessCode = accessCode
		teleportOptions.ReservedServerAccessCode = accessCode
	else
		teleportOptions.ShouldReserveServer = targetServer == "reserved"
	end
	teleportOptions:SetTeleportData(teleportData)

	local ok, err = pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, args.plrList, teleportOptions)
	if not ok then
		warn("[ServerTeleport] teleport failed: " .. tostring(err))
	end
end

function server.getActiveReservedServers(
	poolName: string,
	sortField: ("playerCount" | "liveTime")?,
	sortDesc: boolean?,
	cursor: (number | string)?
): ({ ReservedServerInfo }, (number | string)?, string?)
	if not initialized then
		error("[ServerTeleport] getActiveReservedServers() called before init()")
	end

	local regs = getRegistries(poolName)
	local registry = (sortField == "liveTime") and regs.liveTimeRegistry or regs.registry
	local isDesc = sortDesc ~= false
	local direction = isDesc and Enum.SortDirection.Descending or Enum.SortDirection.Ascending
	local lowerBound = (not isDesc) and cursor or nil
	local upperBound = isDesc and cursor or nil

	local ok, items = pcall(registry.GetRangeAsync, registry, direction, MAX_PICK_SCAN, lowerBound, upperBound)
	if not ok then
		return {}, nil, tostring(items)
	end

	local now = os.time()
	local results = {}
	for _, item in items do
		local info = item.value
		if type(info) == "table" then
			local isFresh = now - (tonumber(info.updatedAt) or 0) <= ACTIVE_WINDOW
			local isOtherServer = info.jobId ~= game.JobId and info.privateServerId ~= game.PrivateServerId
			if type(info.accessCode) == "string" and info.accessCode ~= "" and isFresh and isOtherServer then
				table.insert(results, info)
			end
		end
	end

	local nextCursor = (#items >= MAX_PICK_SCAN) and items[#items].sortKey or nil
	return results, nextCursor, nil
end

local function getServerType(): string
	local v = script:GetAttribute("serverType")
	if v == nil then
		script:GetAttributeChangedSignal("serverType"):Wait()
		v = script:GetAttribute("serverType")
	end
	return v :: string
end

return {
	server = {
		init = server.init,
		teleport = server.teleport,
		getActiveReservedServers = server.getActiveReservedServers,
	},
	getServerType = getServerType,
}
