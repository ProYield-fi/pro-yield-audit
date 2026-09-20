// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
using SafeERC20 for IERC20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Morpho Blue supply strategy (principal parking — yield accrual
/// arrives with the real Morpho Blue adapter in the production pass).
/// FIX (audit 09-20): _doHarvest used to transfer the strategy's ENTIRE USDC
/// balance to `morpho` and book it as "profit" (principal drain booked as
/// yield), and withdraw() let ANY caller pull up to totalSupply of the
/// strategy's balance — bypassing vault auth. Both removed: harvest is an
/// explicit no-op until the real adapter exists, and withdrawal is
/// vault-only (mirrors BaseStrategy.recall authorization).
contract MorphoStrategy is BaseStrategy {
    address public morpho;
    uint256 public totalSupply;

    constructor(address _underlying, address initialOwner, address _morpho)
        BaseStrategy(_underlying, initialOwner, "Morpho")
    {
        require(_morpho != address(0), "Morpho: zero morpho");
        morpho = _morpho;
    }

    function name() external view override returns (string memory) {
        return "Morpho";
    }

    function setMorpho(address morpho_) external onlyOwner nonReentrant {
        require(morpho_ != address(0), "Morpho: zero morpho");
        morpho = morpho_;
    }

    /// Operator-only: park principal in the Morpho market.
    function supply(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Morpho: zero amount");
        underlying.safeTransfer(morpho, amount);
        totalSupply += amount;
    }

    /// Vault-only: pull parked principal back (withdrawal liquidity path).
    /// Was PUBLIC — any caller could drain up to totalSupply (audit finding).
    function withdraw(uint256 amount) external nonReentrant {
        require(msg.sender == vault || msg.sender == owner(), "Morpho: not authorized");
        require(amount > 0, "Morpho: zero amount");
        require(totalSupply >= amount, "Morpho: insufficient supply");
        totalSupply -= amount;
        underlying.safeTransfer(msg.sender, amount);
    }

    /// No yield accrual until the production Morpho Blue adapter lands.
    /// The previous version moved PRINCIPAL to `morpho` and booked it as
    /// profit — a drain vector with fake accounting. Honest zero until real.
    function _doHarvest() internal pure override returns (uint256) {
        return 0;
    }
}
