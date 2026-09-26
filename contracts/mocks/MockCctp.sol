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
    bool public inboundReturnFalse;
    bool public inboundRevert;

    constructor(address _usdc) {
        usdc = MockUSDC(_usdc);
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

    function setInbound(uint256 amount, address to) external {
        inboundAmount = amount;
        inboundTo = to;
        inboundReturnFalse = false;
        inboundRevert = false;
    }

    function setInboundFail(bool returnFalse, bool revertMode) external {
        inboundReturnFalse = returnFalse;
        inboundRevert = revertMode;
    }

    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        if (inboundRevert) revert("mockcctp: boom");
        if (inboundReturnFalse) return false;
        require(inboundTo != address(0), "mockcctp: inbound not set");
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
