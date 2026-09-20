// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Testnet stand-in for the perp venue's funding settlement.
/// In production this is replaced by a Hyperliquid venue adapter that
/// forwards actual funding payments. On testnet it is pre-funded with
/// USDC and pays exactly what the strategy's accrued-funding math says —
/// real token movement, no accounting-only yield.
contract MockFundingSource {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public immutable owner;

    event FundingPaid(address indexed to, uint256 amount);

    constructor(address _usdc) {
        usdc = IERC20(_usdc);
        owner = msg.sender;
    }

    /// Pre-fund the venue (testnet bootstrap).
    function fund(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// Called by the strategy to collect accrued funding.
    /// Auth: open on testnet (any strategy may collect what its math says);
    /// production adapter enforces venue-side position checks.
    function payFunding(address to, uint256 amount) external {
        require(amount > 0, "MockFundingSource: zero");
        usdc.safeTransfer(to, amount);
        emit FundingPaid(to, amount);
    }
}
