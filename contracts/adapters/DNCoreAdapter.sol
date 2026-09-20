// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DNCoreBase} from "./DNCoreBase.sol";

/// @title DNCoreAdapter — delta-neutral execution layer on HyperCore via CoreWriter
/// @notice Thin standalone wrapper over DNCoreBase (the shared execution layer):
/// bridge USDC in/out are the only flow-specific pieces. Keeper pokes; owner sets
/// policy. All CoreWriter actions live in DNCoreBase, gated against silent drops.
/// See docs/DN_COREWRITER_ADAPTER.md for the full design + rollout gates.
contract DNCoreAdapter is Ownable, ReentrancyGuard, DNCoreBase {
    /// @notice USDC on HyperEVM (constructor arg for testability; deploy scripts
    /// pass HLConstants.usdc() — chainid-aware mainnet/testnet).
    IERC20 public immutable usdc;
    address public keeper;

    error Adapter__ZeroKeeper();
    error Adapter__ZeroUsdc();
    error Adapter__ZeroAmount();

    event BridgeToCore(uint256 evmAmount);
    event BridgeToEvm(uint64 weiAmount);
    event KeeperSet(address indexed keeper);

    constructor(address owner_, address keeper_, address usdc_, uint32 perpAsset_, uint256 maxActionUsd6_)
        Ownable(owner_)
        DNCoreBase(perpAsset_, maxActionUsd6_)
    {
        if (keeper_ == address(0)) revert Adapter__ZeroKeeper();
        if (usdc_ == address(0)) revert Adapter__ZeroUsdc();
        keeper = keeper_;
        usdc = IERC20(usdc_);
    }

    /*//////////////////////// Adapter-specific state ////////////////////////*/
    function _keeper() internal view override returns (address) {
        return keeper;
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert Adapter__ZeroKeeper();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /*//////////////////////// Core account lifecycle ////////////////////////*/
    /// @notice Step 1 — bridge USDC EVM→Core (lands in the contract's SPOT balance).
    /// This is what initializes the contract's HyperCore account; any action must
    /// be sent in a LATER block (see design doc).
    function bridgeUsdcToCore(uint256 evmAmount) external onlyKeeper notPaused nonReentrant {
        if (evmAmount == 0) revert Adapter__ZeroAmount();
        emit BridgeToCore(evmAmount);
        _bridgeUsdcIn(usdc, evmAmount);
    }

    /// @notice Step 4 (unwind) — return USDC Core→EVM via sendAsset to the system
    /// address. NOTE: the contract must hold some HYPE on Core to pay transfer gas,
    /// otherwise the action is dropped (silently).
    function bridgeBackToEvm(uint64 weiAmount) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (weiAmount == 0) revert Adapter__ZeroAmount();
        emit BridgeToEvm(weiAmount);
        _sendUsdcToEvm(weiAmount);
    }
}
