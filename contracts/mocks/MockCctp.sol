// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @notice Mock of Circle's CCTP V2 contracts (TokenMessengerV2 + MessageTransmitterV2)
/// in one test double. Outbound burns are recorded and the USDC is pulled in;
/// inbound completions mint a preconfigured amount (or fail, for the guards).
contract MockCctp {
    MockUSDC public usdc;

    struct Burn {
        uint256 amount;
        uint32 destDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinality;
    }

    Burn public lastBurn;
    uint256 public burnCount;

    uint256 public inboundAmount;
    address public inboundTo;
    /// @dev The `destinationCaller` the armed message carries. It is enforced on
    /// relay exactly like CCTP does: 0 = any caller, non-zero = that caller only.
    bytes32 public inboundCallerPin;
    bool public inboundReturnFalse;
    bool public inboundRevert;
    /// @dev CCTP messages are SINGLE-USE (per-message nonce). Armed by
    /// `setInbound`/`setInboundAny`, consumed by the first successful
    /// `receiveMessage` — the second completion of the same message reverts,
    /// exactly like the real MessageTransmitterV2.
    bool public inboundUsed;

    constructor(address _usdc) {
        usdc = MockUSDC(_usdc);
    }

    /// @dev CCTP v2 exposes the paired MessageTransmitter on the TokenMessenger
    /// (`BaseTokenMessenger.localMessageTransmitter`) — executors derive their
    /// relay target from it, so the double (which is both contracts) points at
    /// itself. Mirrors the live shape; no new trust is introduced by derivation.
    function localMessageTransmitter() external view returns (address) {
        return address(this);
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        require(burnToken == address(usdc), "mockcctp: wrong burn token");
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        lastBurn = Burn(amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold);
        burnCount += 1;
    }

    /// @dev Arm the arrival of the message that was JUST burned: the armed
    /// message carries that burn's own `destinationCaller`, so the enforcement
    /// exercised here is the pin the contract actually wrote (not a test-supplied
    /// one). This is the shape F-A regressions must use.
    function setInbound(uint256 amount, address to) external {
        inboundAmount = amount;
        inboundTo = to;
        inboundCallerPin = lastBurn.destinationCaller;
        inboundReturnFalse = false;
        inboundRevert = false;
        inboundUsed = false; // arm a fresh, single-use message
    }

    /// @dev Arm an arrival that is NOT derived from a burn in this mock (e.g. a
    /// strategy-side test simulating a counterpart-chain return, where the burn
    /// happened on another chain and this double only models the destination).
    /// The pin is explicitly "any caller". Do NOT use it to assert a pin — use
    /// `setInbound` for that.
    function setInboundAny(uint256 amount, address to) external {
        inboundAmount = amount;
        inboundTo = to;
        inboundCallerPin = bytes32(0);
        inboundReturnFalse = false;
        inboundRevert = false;
        inboundUsed = false;
    }

    /// @dev Arm an arrival with an EXPLICIT caller pin, for exercising a relay
    /// entry point in isolation (the pin is the contract's own entry point, not a
    /// burn recorded here). Prefer `setInbound` wherever a burn exists.
    function setInboundPinnedFor(uint256 amount, address to, address allowedCaller) external {
        inboundAmount = amount;
        inboundTo = to;
        inboundCallerPin = bytes32(uint256(uint160(allowedCaller)));
        inboundReturnFalse = false;
        inboundRevert = false;
        inboundUsed = false;
    }

    function setInboundFail(bool returnFalse, bool revertMode) external {
        inboundReturnFalse = returnFalse;
        inboundRevert = revertMode;
    }

    /// @dev Mirrors CCTP V2 `MessageTransmitterV2.receiveMessage` semantics:
    /// (1) the message is single-use, and (2) `destinationCaller` of 0 means
    /// "any address may broadcast", while a non-zero value means ONLY that
    /// address may. The shipped mock used to record `destinationCaller` but
    /// never enforce it (audit F-A coverage gap) — it is enforced now, from the
    /// pin the armed message actually carries.
    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        if (inboundRevert) revert("mockcctp: boom");
        if (inboundReturnFalse) return false;
        require(inboundTo != address(0), "mockcctp: inbound not set");
        require(!inboundUsed, "mockcctp: message already used");
        require(
            inboundCallerPin == bytes32(0) || inboundCallerPin == bytes32(uint256(uint160(msg.sender))),
            "mockcctp: destinationCaller: caller not allowed"
        );
        inboundUsed = true;
        usdc.mint(inboundTo, inboundAmount);
        return true;
    }
}

/// @notice Mintable 18-decimals ERC20 standing in for a Pendle PT.
contract MockPT is ERC20 {
    constructor() ERC20("Mock PT", "mPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
