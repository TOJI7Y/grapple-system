-- Connected Discord-GitHub
--credit toji7y2 discord 
-- roblox bunny7y16 

local CollectionService = game:GetService("CollectionService") -- builders tag parts in studio and this finds them, no hardcoded part lists
local Players = game:GetService("Players") -- need it for join/leave events so every player's grapple data gets cleaned up
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- remotes live here because the client has to be able to see them
local RunService = game:GetService("RunService") -- Heartbeat drives the knife flight and the dash every frame
local ServerStorage = game:GetService("ServerStorage") -- knife meshes stay here so clients can't grab or edit them

-- all the tuning numbers live up here so i don't have to hunt for them later
local toolName = "GrappleLauncher" -- the server only accepts shots if this exact tool is equipped
local grappleTag = "GrappleSurface" -- only parts with this tag can be grappled
local maxRange = 320 -- studs, the server clamps the cast to this so the client can't ask for more
local minRange = 1 -- stops you from grappling a wall you're already touching
local knifeSpeed = 320 -- studs per second for the knife flight, kept separate from maxRange on purpose
local dashSpeed = 90 -- studs per second while the player gets pulled in
local arrivalOffset = 3.5 -- how far off the wall you stop, otherwise the character clips into it
local fireCooldown = 0.45 -- per hand, so spamming one side doesn't lock the other
local requestInterval = 0.12 -- global spam gate for the remote, separate from the cooldown above
local maxGrappleTime = 12 -- seconds before a rope cuts itself so nobody hangs forever
local ropeThickness = 0.08
local minRopeLength = 2.5 -- reeling stops here or the root ends up inside the wall
local reelStep = 4 -- studs removed per reel request
local reelInterval = 0.1 -- reel rate limit, the client can fire that remote as fast as it wants
local attachedSwingDamping = 3 -- higher means the swing dies out quicker once you're attached

type HookSide = "Left" | "Right"
type GrapplePhase = "Traveling" | "Dashing" | "Attached" | "Releasing" -- Traveling is knife in the air, Dashing is player moving, Attached is hanging on the rope

-- everything a single hook creates lives in here so cleanup knows exactly what to undo
type GrappleState = {
	hookSide: HookSide,
	phase: GrapplePhase,
	movementRestored: boolean, -- guards restoreCharacterMovement from running twice
	humanoid: Humanoid,
	root: BasePart,
	target: BasePart,
	rootAttachment: Attachment,
	targetAttachment: Attachment,
	rope: RopeConstraint, -- the real physics rope, never rendered
	visualRope: Beam, -- what players actually see
	heldKnife: BasePart?, -- optional, the knife in the character's hand that gets hidden while it's thrown
	heldKnifeTransparency: number?,
	projectile: BasePart?,
	projectileAttachment: Attachment?,
	dashConnection: RBXScriptConnection?,
	-- these three remember what the character was like before the grapple so release can put it back
	wasAnchored: boolean,
	wasAutoRotate: boolean,
	wasPlatformStand: boolean,
	diedConnection: RBXScriptConnection?,
	targetConnections: {RBXScriptConnection}, -- watches the target part so the rope cuts if it gets broken
}

-- player -> hand -> state, so each player can have a left and a right rope at the same time
-- (they still share one root, so only one of them can be dashing at once, see isGrappleInTransit)
local activeGrapples: {[Player]: {[HookSide]: GrappleState}} = {}
local cooldowns: {[Player]: {[HookSide]: number}} = {}
local lastRequests: {[Player]: number} = {}
local lastReelRequests: {[Player]: number} = {}

-- grabs the folder if it's already there, makes it if not
local function getOrCreateFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing:IsA("Folder"), name .. " must be a Folder") -- fail loudly if something else is squatting on the name
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent -- parent set last so it doesn't replicate half built
	return folder
end

local function getOrCreateRemote(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteEvent"), name .. " must be a RemoteEvent")
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

-- client only tells us where it's aiming, the server does the actual raycast and checks
local remotes = getOrCreateFolder(ReplicatedStorage, "GrappleRemotes")
local fireGrapple = getOrCreateRemote(remotes, "FireGrapple")
local releaseGrapple = getOrCreateRemote(remotes, "ReleaseGrapple")
local reelGrapple = getOrCreateRemote(remotes, "ReelGrapple")
local knifeAssets = ServerStorage:FindFirstChild("GrappleKnifeAssets") -- FindFirstChild not WaitForChild, a missing folder would hang the whole script and the remotes would never connect
local soundFolder = workspace:FindFirstChild("Sound ") -- same idea, missing sounds shouldn't break the grapple
local throwSoundNames: {[HookSide]: string} = {
	Left = "knife swing",
	Right = "Knife swing", -- different casing than the left one, FindFirstChild is case sensitive so this has to match the asset name
}

-- returns nils if the player is respawning or dead so callers can just bail
-- head is where the aim starts, root is the part we actually move
local function getCharacterParts(player: Player): (Model?, Humanoid?, BasePart?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil, nil -- no character yet, happens between respawns
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootInstance = character:FindFirstChild("HumanoidRootPart")
	local headInstance = character:FindFirstChild("Head")

	if not humanoid or humanoid.Health <= 0 then
		return character, humanoid, nil, nil -- dead players shouldn't be able to fire
	end

	if not rootInstance or not rootInstance:IsA("BasePart") then
		return character, humanoid, nil, nil -- IsA check also narrows the type so the rest of the script is happy
	end

	local head: BasePart = rootInstance -- fall back to the root if there's no head for some reason
	if headInstance and headInstance:IsA("BasePart") then
		head = headInstance
	end

	return character, humanoid, rootInstance, head
end

-- the tool has to be equipped, enabled and have its handle, otherwise an exploiter could fire without holding it
local function hasEquippedLauncher(character: Model): boolean
	local tool = character:FindFirstChild(toolName) -- equipped tools sit directly under the character, in the backpack they'd be missed
	if not tool or not tool:IsA("Tool") then
		return false
	end

	if not tool.Enabled then
		return false -- lets other scripts disable the launcher (stuns etc) without touching this one
	end

	if tool.RequiresHandle and not tool:FindFirstChild("Handle") then
		return false
	end

	return true
end

-- nan is the only number that isn't equal to itself, and the abs check catches inf
local function isFiniteNumber(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

-- remote args can be literally anything so check before we trust it as a Vector3
local function isValidAimDirection(aimDirection: any): boolean
	if typeof(aimDirection) ~= "Vector3" then
		return false -- typeof not type, type() just says "userdata" for roblox types
	end

	if not isFiniteNumber(aimDirection.X) then
		return false
	end

	if not isFiniteNumber(aimDirection.Y) then
		return false
	end

	if not isFiniteNumber(aimDirection.Z) then
		return false -- one nan in here would poison the raycast and the cframe math after it
	end

	return aimDirection.Magnitude > 0.001 -- zero vector would break .Unit
end

-- quick spam gate, separate from the per-hand cooldown
local function canSendFireRequest(player: Player): boolean
	local now = os.clock() -- os.clock is monotonic so it can't jump around like os.time can
	local previousRequest = lastRequests[player] or 0

	if now - previousRequest < requestInterval then
		return false
	end

	lastRequests[player] = now -- only stamped on a request that passes, so dropped ones don't extend the wait
	return true
end

-- each hand has its own cooldown since they can come back at different times
local function isOnCooldown(player: Player, hookSide: HookSide): boolean
	local playerCooldowns = cooldowns[player]
	return playerCooldowns ~= nil and os.clock() < (playerCooldowns[hookSide] or 0) -- the nil check covers players who haven't fired yet
end

local function setCooldown(player: Player, hookSide: HookSide)
	local playerCooldowns = cooldowns[player]
	if not playerCooldowns then
		playerCooldowns = {}
		cooldowns[player] = playerCooldowns -- made lazily so players who never grapple don't cost a table
	end
	playerCooldowns[hookSide] = os.clock() + fireCooldown -- stored as the time it ends, so checking is one comparison
end

-- ignore the player's own character so the cast doesn't hit their arms or the tool
local function getRaycastParams(character: Model): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {character}
	params.IgnoreWater = true -- water shouldn't block a shot
	params.RespectCanCollide = false -- cancollide false parts can still be grapple surfaces
	return params
end

-- only tagged, anchored, queryable parts can be grappled
-- builders can also set the GrappleDisabled attribute to turn a part off without removing the tag
local function isValidTarget(instance: Instance): boolean
	if not instance:IsA("BasePart") then
		return false
	end

	if not instance.Anchored then
		return false -- the rope anchor is stored on the part so an unanchored one would just get dragged around
	end

	if not instance.CanQuery then
		return false
	end

	if not CollectionService:HasTag(instance, grappleTag) then
		return false
	end

	if instance:GetAttribute("GrappleDisabled") == true then
		return false -- == true on purpose so a missing attribute (nil) counts as enabled
	end

	return true
end

-- spherecast instead of a plain ray so aiming feels a bit more forgiving
-- returns part, position, normal or all nils on a miss
local function getTargetHit(
	character: Model,
	origin: Vector3,
	aimDirection: Vector3
): (BasePart?, Vector3?, Vector3?)
	local displacement = aimDirection.Unit * maxRange -- .Unit so a huge client vector can't stretch the cast past maxRange
	local params = getRaycastParams(character)
	local result = workspace:Spherecast(origin, 1.25, displacement, params) -- 1.25 stud radius is the forgiveness
	if not result or not isValidTarget(result.Instance) then
		return nil, nil, nil -- hitting a non grapple part first blocks the shot like a normal wall would
	end

	local hitDistance = (result.Position - origin).Magnitude
	if hitDistance < minRange or hitDistance > maxRange then
		return nil, nil, nil
	end

	return result.Instance, result.Position, result.Normal
end

local function disconnectConnection(connection: RBXScriptConnection?)
	if connection and connection.Connected then -- Connected check because cleanup can run more than once
		connection:Disconnect()
	end
end

-- tears down everything one shot made, safe to call at any point mid-grapple
local function destroyGrappleObjects(state: GrappleState)
	disconnectConnection(state.diedConnection)
	for _, connection in ipairs(state.targetConnections) do
		disconnectConnection(connection)
	end
	table.clear(state.targetConnections) -- clear instead of making a new table so the state keeps the same reference

	if state.dashConnection then
		state.dashConnection:Disconnect() -- has to go first or the heartbeat would keep running on destroyed objects
		state.dashConnection = nil
	end

	if state.projectile then
		state.projectile:Destroy()
		state.projectile = nil
	end

	-- put the held knife back to whatever transparency it had before
	if state.heldKnife and state.heldKnife.Parent and state.heldKnifeTransparency ~= nil then
		state.heldKnife.Transparency = state.heldKnifeTransparency
	end

	-- Parent checks below because the character can already be gone by the time this runs (death, leaving)
	if state.rope.Parent then
		state.rope:Destroy()
	end

	if state.visualRope.Parent then
		state.visualRope:Destroy()
	end

	if state.rootAttachment.Parent then
		state.rootAttachment:Destroy()
	end

	if state.targetAttachment.Parent then
		state.targetAttachment:Destroy()
	end
end

-- pcall because roblox sometimes errors if the root is already gone
local function restoreCharacterOwnership(root: BasePart)
	if not root.Parent then
		return
	end

	pcall(function()
		root:SetNetworkOwnershipAuto() -- hands physics back to the client so movement feels normal again
	end)
end

-- can get called from a few places in the same frame, the movementRestored flag stops it running twice
-- stopMovement = true kills leftover velocity (used on release), false keeps the momentum (used on arrival)
local function restoreCharacterMovement(state: GrappleState, stopMovement: boolean)
	if state.movementRestored then
		return
	end

	state.movementRestored = true
	if state.root.Parent then
		state.root.Anchored = state.wasAnchored -- not just false, in case something else had it anchored before we started
		if stopMovement then
			state.root.AssemblyLinearVelocity = Vector3.zero
			state.root.AssemblyAngularVelocity = Vector3.zero
		end
	end

	if state.humanoid.Parent then
		state.humanoid.AutoRotate = state.wasAutoRotate
		state.humanoid.PlatformStand = state.wasPlatformStand
		if state.humanoid.Health > 0 then
			state.humanoid:ChangeState(Enum.HumanoidStateType.Running) -- without this the humanoid can stay stuck in the Physics state
		end
	end

	restoreCharacterOwnership(state.root)
end

-- releases just one hand, the other rope stays attached
local function clearGrappleSide(player: Player, hookSide: HookSide)
	local playerGrapples = activeGrapples[player]
	local state = playerGrapples and playerGrapples[hookSide]
	if not playerGrapples or not state then
		return -- nothing on that hand, so calling this twice is harmless
	end

	state.phase = "Releasing"
	playerGrapples[hookSide] = nil -- removed from the table before cleanup so nothing can find it half destroyed
	-- nothing left for this player so drop their table too
	if next(playerGrapples) == nil then
		activeGrapples[player] = nil
	end

	destroyGrappleObjects(state)
	restoreCharacterMovement(state, true)
end

-- pass a side to release one hand, or nothing to release both (death, respawn, leaving)
local function clearGrapple(player: Player, hookSide: HookSide?)
	if hookSide then
		clearGrappleSide(player, hookSide)
		return
	end

	local playerGrapples = activeGrapples[player]
	if not playerGrapples then
		return
	end

	-- copy the keys first so we're not removing stuff from the table while looping over it
	local hookSides: {HookSide} = {}
	for side in pairs(playerGrapples) do
		table.insert(hookSides, side)
	end

	for _, side in ipairs(hookSides) do
		clearGrappleSide(player, side)
	end
end

-- both hooks can stay attached but only one can be moving the root at a time
local function isGrappleInTransit(player: Player): boolean
	local playerGrapples = activeGrapples[player]
	if not playerGrapples then
		return false
	end

	for _, state in pairs(playerGrapples) do
		if not state.movementRestored then -- movement only gets restored once the dash lands, so false means still moving
			return true
		end
	end

	return false
end

local function makeAttachment(name: string, parent: BasePart, position: Vector3): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Position = position -- local to the parent part
	attachment.Parent = parent
	return attachment
end

-- optional sounds, if one is missing we just skip it
local function playSound(name: string, parent: BasePart)
	if not soundFolder then
		return
	end

	local template = soundFolder:FindFirstChild(name)
	if not template or not template:IsA("Sound") then
		return
	end

	-- clone so overlapping shots don't cut each other off
	local sound = template:Clone()
	sound.Parent = parent -- parented to a part so it plays from that spot in 3d
	sound:Play()
	sound.Ended:Once(function() -- Once so the connection cleans itself up
		sound:Destroy()
	end)
end

-- points the knife along its flight direction
-- swaps the up vector when aiming almost straight up/down, otherwise lookAt flips out
local function getProjectileCFrame(position: Vector3, direction: Vector3): CFrame
	local unitDirection = direction.Unit
	local upDirection = math.abs(unitDirection:Dot(Vector3.yAxis)) > 0.98 and Vector3.zAxis or Vector3.yAxis -- dot near 1 means we're nearly parallel with the up vector
	return CFrame.lookAt(position, position + unitDirection, upDirection)
		* CFrame.Angles(-math.pi / 2, 0, 0) -- the mesh points along its Y axis, not Z, so rotate it to line up
end

-- the RopeConstraint is the real physics rope, it's invisible and the beam is what players actually see
local function makeRope(
	root: BasePart,
	rootAttachment: Attachment,
	targetAttachment: Attachment,
	initialDistance: number,
	hookSide: HookSide
): RopeConstraint
	local rope = Instance.new("RopeConstraint")
	rope.Name = "Active" .. hookSide .. "GrappleRope"
	rope.Attachment0 = rootAttachment
	rope.Attachment1 = targetAttachment
	rope.Length = initialDistance -- starts at the current distance so nothing snaps on creation
	rope.WinchEnabled = false -- length is changed from code, not by the winch motor
	rope.Thickness = ropeThickness
	rope.Visible = false
	rope.Restitution = 0 -- no bounce when the rope goes taut
	rope.Parent = root
	return rope
end

-- server owns the root while we're moving it so everyone sees the same thing
local function setServerOwnership(root: BasePart)
	pcall(function()
		root:SetNetworkOwner(nil) -- nil means the server, and the client can't fight the dash with its own physics
	end)
end

-- physics rope is attached to the root center so it doesn't twist the character
-- the beam starts from the knife in hand if there is one
local function createGrappleState(
	humanoid: Humanoid,
	root: BasePart,
	target: BasePart,
	worldPosition: Vector3,
	surfaceNormal: Vector3,
	hookSide: HookSide
): GrappleState
	local rootAttachment = makeAttachment(
		hookSide .. "GrappleCharacterAttachment",
		root,
		Vector3.zero
	)

	-- store the anchor in the target's local space so it follows if the part moves or rotates
	local anchorPosition = worldPosition + surfaceNormal * 0.08 -- tiny push off the surface so the knife doesn't z-fight with it
	local localAnchorPosition = target.CFrame:PointToObjectSpace(anchorPosition)
	local targetAttachment = makeAttachment(
		hookSide .. "GrappleTargetAttachment",
		target,
		localAnchorPosition
	)

	local distance = (targetAttachment.WorldPosition - rootAttachment.WorldPosition).Magnitude
	local rope = makeRope(root, rootAttachment, targetAttachment, distance, hookSide)
	local visualAttachment = rootAttachment -- default start of the beam, replaced below if the character has a knife
	local character = root.Parent
	local knifeName = hookSide .. "GrappleKnife"
	local knife = character and character:FindFirstChild(knifeName)
	local knifeAttachment = knife and knife:FindFirstChild("GrappleCableAttachment")
	local heldKnife = if knife and knife:IsA("BasePart") then knife else nil -- the if expression keeps the type as BasePart? instead of Instance?
	if knifeAttachment and knifeAttachment:IsA("Attachment") then
		visualAttachment = knifeAttachment
	end

	local visualRope = Instance.new("Beam")
	visualRope.Name = hookSide .. "GrappleVisualRope"
	visualRope.Attachment0 = visualAttachment
	visualRope.Attachment1 = targetAttachment
	visualRope.FaceCamera = true -- flat beams look paper thin from the side without this
	visualRope.Width0 = 0.08
	visualRope.Width1 = 0.05 -- slightly thinner at the wall end
	visualRope.Color = ColorSequence.new(Color3.fromRGB(205, 215, 230))
	visualRope.Parent = root

	local state: GrappleState = {
		hookSide = hookSide,
		phase = "Traveling",
		movementRestored = false,
		humanoid = humanoid,
		root = root,
		target = target,
		rootAttachment = rootAttachment,
		targetAttachment = targetAttachment,
		rope = rope,
		visualRope = visualRope,
		heldKnife = heldKnife,
		heldKnifeTransparency = heldKnife and heldKnife.Transparency or nil,
		projectile = nil,
		projectileAttachment = nil,
		dashConnection = nil,
		wasAnchored = root.Anchored, -- snapshots taken now, before beginGrapple changes any of them
		wasAutoRotate = humanoid.AutoRotate,
		wasPlatformStand = humanoid.PlatformStand,
		diedConnection = nil,
		targetConnections = {},
	}

	return state
end

-- the target can stop being valid after the shot (destroyed, unanchored, tag removed etc) so we watch for that and cut the rope
local function connectGrappleCleanup(player: Player, state: GrappleState)
	state.diedConnection = state.humanoid.Died:Connect(function()
		clearGrapple(player) -- both hands, a dead player shouldn't keep a rope
	end)

	local function clearIfInvalid()
		local playerGrapples = activeGrapples[player]
		-- the == state check makes sure we only cut this exact grapple and not a newer one on the same hand
		if playerGrapples and playerGrapples[state.hookSide] == state and not isValidTarget(state.target) then
			clearGrapple(player, state.hookSide)
		end
	end

	table.insert(state.targetConnections, state.target.Destroying:Connect(function()
		clearGrapple(player, state.hookSide)
	end))
	table.insert(state.targetConnections, CollectionService:GetInstanceRemovedSignal(grappleTag):Connect(function(instance: Instance)
		if instance == state.target then -- this signal fires for every tagged part so filter for ours
			clearGrapple(player, state.hookSide)
		end
	end))
	table.insert(state.targetConnections, state.target:GetPropertyChangedSignal("Anchored"):Connect(clearIfInvalid))
	table.insert(state.targetConnections, state.target:GetPropertyChangedSignal("CanQuery"):Connect(clearIfInvalid))
	table.insert(state.targetConnections, state.target:GetAttributeChangedSignal("GrappleDisabled"):Connect(clearIfInvalid))

	-- hard timeout so a grapple can't just sit there forever
	-- the state check makes sure we don't kill a newer grapple on the same side
	task.delay(maxGrappleTime, function()
		local playerGrapples = activeGrapples[player]
		if playerGrapples and playerGrapples[state.hookSide] == state then
			clearGrapple(player, state.hookSide)
		end
	end)
end

-- two stages: knife flies to the wall first, then the player gets pulled over at a fixed speed
local function beginGrapple(
	player: Player,
	humanoid: Humanoid,
	root: BasePart,
	target: BasePart,
	worldPosition: Vector3,
	surfaceNormal: Vector3,
	hookSide: HookSide
)
	local state = createGrappleState(
		humanoid,
		root,
		target,
		worldPosition,
		surfaceNormal,
		hookSide
	)

	local playerGrapples = activeGrapples[player]
	if not playerGrapples then
		playerGrapples = {}
		activeGrapples[player] = playerGrapples
	end
	playerGrapples[hookSide] = state -- registered right away so the cleanup functions can find it
	if state.heldKnife then
		state.heldKnife.Transparency = 1 -- hide the knife in hand since the projectile is the one flying now
	end
	-- take over the character, the original flags are already saved in state
	setServerOwnership(root)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	humanoid.AutoRotate = false -- otherwise the humanoid fights the rotation we set during the dash
	humanoid.PlatformStand = true
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	root.Anchored = true -- anchored so we can drive it with CFrame instead of fighting physics

	-- positions are worked out from the start point each frame so error doesn't build up
	local startPosition = root.Position
	local rotation = root.CFrame.Rotation
	local destination = state.targetAttachment.WorldPosition + surfaceNormal * arrivalOffset
	local displacement = destination - startPosition
	-- flatten y so the character doesn't tilt when the target is way above or below
	local horizontalDisplacement = Vector3.new(displacement.X, 0, displacement.Z)
	local travelRotation = rotation -- keeps the current facing if the target is straight above or below
	if horizontalDisplacement.Magnitude > 0.001 then
		travelRotation = CFrame.lookAt(Vector3.zero, horizontalDisplacement.Unit).Rotation
	end
	local distance = displacement.Magnitude
	-- already basically on top of the target, nothing to do
	if distance < 0.1 then
		clearGrapple(player, hookSide)
		setCooldown(player, hookSide)
		return
	end

	-- knife visually leaves from the hand, the hidden physics rope still starts at the root
	local hookStart = (state.visualRope.Attachment0 :: Attachment).WorldPosition -- cast because Attachment0 is typed as nullable but we set it a few lines up
	local physicsHookStart = state.rootAttachment.WorldPosition
	local hookEnd = state.targetAttachment.WorldPosition
	local hookDistance = (hookEnd - hookStart).Magnitude
	-- flight time scales with distance but clamped so close shots aren't instant and far ones aren't slow
	local hookDuration = math.clamp(hookDistance / knifeSpeed, 0.15, 0.55)
	local hookElapsed = 0 -- accumulated with deltaTime instead of os.clock so a lag spike doesn't skip the animation
	local traveled = 0
	local templateName = hookSide == "Left" and "ShadowKnife" or "ScarletKnife"
	local template = knifeAssets and knifeAssets:FindFirstChild(templateName)
	local projectile: BasePart
	if template and template:IsA("MeshPart") then
		projectile = template:Clone()
		projectile.Size = template.Size * 0.62
	else
		-- no mesh found so use a tiny invisible part, the grapple still works
		projectile = Instance.new("Part")
		projectile.Size = Vector3.new(0.2, 0.2, 0.2)
		projectile.Transparency = 1
	end
	projectile.Name = hookSide .. "GrappleProjectile"
	projectile.Anchored = true -- moved by CFrame every frame, no physics needed
	projectile.CanCollide = false
	projectile.CanQuery = false -- so our own spherecast never hits the knife
	projectile.CanTouch = false
	projectile.Massless = true
	projectile.CFrame = getProjectileCFrame(hookStart, hookEnd - hookStart)
	projectile.Parent = workspace
	playSound(throwSoundNames[hookSide], state.heldKnife or root)
	playSound("Grapple sfx", projectile)

	local projectileAttachment = Instance.new("Attachment")
	projectileAttachment.Name = "GrappleCableAttachment"
	if projectile:IsA("MeshPart") then
		projectileAttachment.Position = Vector3.new(0, -projectile.Size.Y * 0.4, 0) -- rope ties on near the back of the knife, not its center
	end
	projectileAttachment.Parent = projectile
	state.projectile = projectile
	state.projectileAttachment = projectileAttachment
	state.rope.Attachment1 = projectileAttachment -- rope follows the knife while it flies, then moves to the wall
	state.visualRope.Attachment1 = projectileAttachment
	state.rope.Length = 0.1

	state.dashConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
		local playerGrapples = activeGrapples[player]
		if not playerGrapples or playerGrapples[hookSide] ~= state or not root.Parent then
			clearGrapple(player, hookSide) -- this state got replaced or the character is gone, so stop ticking
			return
		end
		if not isValidTarget(state.target) then
			clearGrapple(player, hookSide)
			return
		end

		-- phase 1: knife flies out in a straight line, then the rope switches over to the wall
		if state.phase == "Traveling" then
			hookElapsed = math.min(hookDuration, hookElapsed + deltaTime) -- min so progress tops out at exactly 1
			local progress = hookElapsed / hookDuration
			local projectilePosition = hookStart:Lerp(hookEnd, progress)
			projectile.CFrame = getProjectileCFrame(projectilePosition, hookEnd - hookStart)
			state.rope.Length = math.max(0.1, (projectilePosition - physicsHookStart).Magnitude) -- grows with the knife so the rope looks like it's paying out

			if hookElapsed >= hookDuration then
				state.rope.Attachment1 = state.targetAttachment -- the knife landed, so the rope hooks onto the wall now
				state.rope.Length = (state.rootAttachment.WorldPosition - hookEnd).Magnitude
				local projectileDirection = (hookEnd - hookStart).Unit
				projectile.CFrame = getProjectileCFrame(
					hookEnd - projectileDirection * projectile.Size.Y * 0.4, -- pulled back a bit so the blade looks stuck in the wall
					projectileDirection
				)
				projectile.Parent = state.target -- parented to the wall so the knife goes away with it if the part is removed
				playSound("Knife Throw Hit", projectile)
				state.phase = "Dashing"
			end
			return
		end

		-- once attached we just bleed off the sideways velocity so the player doesn't swing around forever
		if state.phase == "Attached" then
			local radial = state.rootAttachment.WorldPosition - state.targetAttachment.WorldPosition
			if radial.Magnitude > 0.001 then
				local velocity = root.AssemblyLinearVelocity
				local radialDirection = radial.Unit
				-- whatever's left after removing the along-the-rope part is the circling motion
				local swingVelocity = velocity - radialDirection * velocity:Dot(radialDirection)
				root.AssemblyLinearVelocity = velocity - swingVelocity * math.min(attachedSwingDamping * deltaTime, 1) -- min 1 so a big deltaTime can't overshoot and reverse the swing
				root.AssemblyAngularVelocity *= math.exp(-attachedSwingDamping * deltaTime) -- exponential decay, looks the same at any framerate
			end
			return
		end

		if state.phase ~= "Dashing" then
			return -- Releasing, nothing left to do
		end

		-- phase 2: pull the player along the line at a constant speed
		traveled = math.min(distance, traveled + dashSpeed * deltaTime) -- capped so we never overshoot the destination
		local position = startPosition + displacement.Unit * traveled
		root.CFrame = CFrame.new(position) * travelRotation
		state.rope.Length = (
			state.rootAttachment.WorldPosition - state.targetAttachment.WorldPosition
		).Magnitude
		-- keep the other hand's rope from going slack or stretching while we move
		for _, attachedState in pairs(playerGrapples) do
			if attachedState ~= state and attachedState.phase == "Attached" then
				attachedState.rope.Length = (
					attachedState.rootAttachment.WorldPosition
					- attachedState.targetAttachment.WorldPosition
				).Magnitude
			end
		end

		if traveled >= distance then
			state.phase = "Attached"
			restoreCharacterMovement(state, false) -- false keeps the speed so you carry momentum off the wall
		end
	end)

	connectGrappleCleanup(player, state)
	setCooldown(player, hookSide)
end

-- clicking again on a hand that's already out releases it
-- remote args stay as 'any' until they're checked
local function handleFireRequest(player: Player, aimDirection: any, requestedSide: any)
	if not canSendFireRequest(player) then
		return
	end

	if requestedSide ~= "Left" and requestedSide ~= "Right" then
		return -- never trust the side string from the client
	end
	local hookSide: HookSide = requestedSide -- safe to narrow now that it's been checked

	local playerGrapples = activeGrapples[player]
	if playerGrapples and playerGrapples[hookSide] then
		clearGrapple(player, hookSide)
		return
	end

	if isGrappleInTransit(player) or isOnCooldown(player, hookSide) then
		return
	end

	if not isValidAimDirection(aimDirection) then
		return
	end

	local character, humanoid, root, head = getCharacterParts(player)
	if not character or not humanoid or not root or not head then
		return
	end

	if not hasEquippedLauncher(character) then
		return
	end

	local target, position, normal = getTargetHit(character, head.Position, aimDirection) -- cast starts from the server's head position, not anything the client sent
	if not target or not position or not normal then
		return
	end

	beginGrapple(player, humanoid, root, target, position, normal, hookSide)
end

local function handleReleaseRequest(player: Player)
	clearGrapple(player) -- no side given so it drops both
end

-- reel pulls the rope shorter, rate limited so the client can't spam it
local function handleReelRequest(player: Player, requestedSide: any)
	if requestedSide ~= "Left" and requestedSide ~= "Right" then
		return
	end

	local now = os.clock()
	if now - (lastReelRequests[player] or 0) < reelInterval then
		return
	end
	lastReelRequests[player] = now

	local playerGrapples = activeGrapples[player]
	local hookSide: HookSide = requestedSide
	local state = playerGrapples and playerGrapples[hookSide]
	if not state or state.phase ~= "Attached" then
		return -- can't reel a rope that isn't attached yet
	end

	state.rope.Length = math.max(minRopeLength, state.rope.Length - reelStep)
end

-- CharacterRemoving fires on respawn and on leaving, and death is already covered by the Died connection in connectGrappleCleanup
local function bindPlayer(player: Player)
	player.CharacterRemoving:Connect(function()
		clearGrapple(player)
	end)
end

fireGrapple.OnServerEvent:Connect(handleFireRequest)
releaseGrapple.OnServerEvent:Connect(handleReleaseRequest)
reelGrapple.OnServerEvent:Connect(handleReelRequest)

Players.PlayerAdded:Connect(bindPlayer)

Players.PlayerRemoving:Connect(function(player)
	clearGrapple(player)
	cooldowns[player] = nil -- these tables are keyed by player so they'd leak if we never cleared them
	lastRequests[player] = nil
	lastReelRequests[player] = nil
end)

-- catch anyone who joined before this script started
for _, player in ipairs(Players:GetPlayers()) do
	bindPlayer(player)
end
