_ENV.require = _G.import or require
local clock = time or os.clock
local CORE_ENV = CoreDebug and true

if not CORE_ENV then return end

-- @CoreModules
local Bitarray = require("BitArray")
local Crockford32 = require("Crockford32")
local Deque = require("Deque")
local GOAP = require("GOAP")
local Heap = require("Heap")
local Logic = require("Logic")
local Luapp = require("Luapp")
local Snippets = require("Snippets")
local Xoshiro256 = require("Xoshiro256")

-- @TrustedEvents
local AckAbility = require("AckAbility")
local Base64 = require("Base64")
local BitVector32 = require("BitVector32")
local Maid = require("Maid")
local MessagePack = require("MessagePack")
local Queue = require("Queue")
local ReliableEndpoint = require("ReliableEndpoint")
local Signals = require("Signals")
local TrustedEvents = require("TrustedEvents")
local UnreliableEndpoint = require("UnreliableEndpoint")

-- @GameplayModules
local Agent = require("Agent")
local CharacterController = require("CharacterController")
local DebugDraw = require("DebugDraw")(true)
local Grid = require("Grid")
local SpringAnimator = require("SpringAnimator")
local StateMachine = require("StateMachine")


local Signals = require("Signals")
local GOAP = require("GOAP")

if Environment.IsServer() then


else -- Client

end
