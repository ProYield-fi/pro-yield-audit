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
    uint256 public totalFeesReceived;   // CUMULATIVE lifetime fees (see receiveFees)
    uint256 public totalFeesRouted;
    /// @notice Peak balance ever observed in this contract. Kept for the
    /// dashboard's "fees sitting here" read, which must not go backwards as
    /// fees are routed out.
    uint256 public peakBalance;

    mapping(address => uint256) public routedTo;

    event FeesReceived(uint256 amount, uint256 total);
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
    ///
    /// AUDIT F-13 FIX. This used to be a HIGH-WATER MARK: it only assigned
    /// `totalFeesReceived = bal` when `bal` exceeded the stored value, so after
    /// the first `route()` drained the contract, every later fee was smaller than
    /// the peak and was silently IGNORED — the counter and the `FeesReceived`
    /// event froze permanently, so lifetime fee income read as whatever the
    /// first recycle happened to be. It is now CUMULATIVE: each observation adds
    /// only the amount that has actually arrived since the last accounting pass,
    /// which is derived from `totalFeesRouted`.
    function receiveFees() external {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > peakBalance) peakBalance = bal;
        // Lifetime USDC that has passed through this contract = what is still here
        // plus what has already been routed out. Anything above the amount
        // already counted is a NEW arrival. (Do NOT add totalFeesRouted to
        // totalFeesReceived on the right-hand side — routed fees are already
        // included in the received total, so that would double-count them.)
        uint256 seen = bal + totalFeesRouted;
        if (seen > totalFeesReceived) {
            uint256 amount = seen - totalFeesReceived;
            totalFeesReceived += amount;
            emit FeesReceived(amount, totalFeesReceived);
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
