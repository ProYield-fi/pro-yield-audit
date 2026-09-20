// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Receives the vault's USDC performance fees and routes them.
/// FIX (audit 09-20): the previous version had pendingFees that nothing could
/// ever set, totalFees that decremented without ever incrementing, and a
/// distribute() that paid the CALLER — entirely non-functional. This version
/// tracks real received fees and gives the owner explicit, event-logged
/// routing (insurance fund / staking rewards / treasury). Fee recycling is a
/// deliberate owner action, never an implicit one.
contract FeeDistributor is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc; // fee currency (was pyd — vault fees are USDC)
    uint256 public totalFeesReceived;
    uint256 public totalFeesRouted;

    mapping(address => uint256) public routedTo;

    event FeesReceived(uint256 amount);
    event FeesRouted(address indexed to, uint256 amount);

    constructor(address _usdc) Ownable(msg.sender) {
        require(_usdc != address(0), "FeeDistributor: zero usdc");
        usdc = IERC20(_usdc);
    }

    function name() external pure returns (string memory) {
        return "FeeDistributor";
    }

    /// @notice The vault's performance fee lands here as a plain USDC transfer
    /// (no hook). Anyone may reconcile accounting after a transfer.
    function receiveFees() external {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > totalFeesReceived) {
            totalFeesReceived = bal;
            emit FeesReceived(bal);
        }
    }

    /// @notice Route collected fees to a destination (insurance fund, staking
    /// rewards pool, treasury). Owner-only, event-logged — fee recycling is
    /// an explicit operator decision.
    function route(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "FeeDistributor: zero to");
        uint256 bal = usdc.balanceOf(address(this));
        if (amount > bal) amount = bal;
        require(amount > 0, "FeeDistributor: nothing to route");
        usdc.safeTransfer(to, amount);
        totalFeesRouted += amount;
        routedTo[to] += amount;
        emit FeesRouted(to, amount);
    }
}
