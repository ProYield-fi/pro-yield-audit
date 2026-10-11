// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";

/// @notice The one thing the cap math needs from the vault.
interface IVaultBook {
    function totalAssets() external view returns (uint256);
}

/// @title FrontierBase — the gated entry to exotic venues (the Frontier tier).
/// @notice Every Frontier venue adapter inherits this. It enforces the two
/// rules that make exotic venues acceptable inside an otherwise conservative
/// vault, IN CODE rather than in policy documents:
///
///   1. GATE — no money moves into the venue until the owner flips
///      `venueCleared` after the per-name due diligence passes. Fail-closed:
///      the default is locked, and only the SUPPLY path is gated (funds-out
///      — recall/withdraw — is NEVER gated, so the gate can never trap money).
///
///   2. PER-NAME CAP — this venue can never be supplied past
///      `maxShareBps` of the vault's whole book. The policy cap is ≤15%
///      (`MAX_SHARE_BPS_CEILING = 1500`); the owner may set it LOWER, never
///      higher. The check is fail-closed: an unwired vault or an empty book
///      makes supply impossible, not unrestricted.
///
/// Honest-accounting note: the cap is a SUPPLY gate. A venue's own yield or
/// loss can drift the live share afterwards (the mark moves, the gate is not
/// a clamp on venue revaluation) — the keeper monitor watches
/// `projectedShareBps(0)` and the runbook documents that drift. What the cap
/// guarantees is that no single venue can be deliberately overloaded.
abstract contract FrontierBase is BaseStrategy {
    constructor(address _underlying, address initialOwner, string memory symbol_)
        BaseStrategy(_underlying, initialOwner, symbol_)
    {}

    bool public venueCleared;
    uint256 public maxShareBps = 1500;
    uint256 public constant MAX_SHARE_BPS_CEILING = 1500;

    event VenueCleared(bool cleared);
    event MaxShareSet(uint256 bps);

    error Frontier__NotCleared();
    error Frontier__CapExceeded();
    error Frontier__CapUnverifiable();
    error Frontier__BpsTooHigh();

    /// @notice DD gate. Owner-only, one-way per decision (can re-lock, e.g.
    /// during an incident — locking never blocks withdrawals).
    function setVenueCleared(bool cleared) external onlyOwner nonReentrant {
        venueCleared = cleared;
        emit VenueCleared(cleared);
    }

    /// @notice Tighten the per-venue cap. The 15% policy ceiling cannot be
    /// raised by anyone, ever (not even the owner) — that is the point.
    function setMaxShareBps(uint256 bps) external onlyOwner nonReentrant {
        if (bps > MAX_SHARE_BPS_CEILING) revert Frontier__BpsTooHigh();
        maxShareBps = bps;
        emit MaxShareSet(bps);
    }

    /// @notice Share of the vault's whole book this venue currently holds.
    /// Supply moves idle→position INSIDE this strategy, so supplying does not
    /// change the strategy's total (the vault's exposure to this venue is the
    /// strategy's whole balance, however it is internally parked). New money
    /// arrives via the vault's allocate BEFORE deploy, so it is already in
    /// `totalAssets()` when the gate reads it. Fail-closed on an unwired vault
    /// (0x0) or an empty book (the share would be infinite).
    function projectedShareBps() public view returns (uint256) {
        address v = vault;
        if (v == address(0)) revert Frontier__CapUnverifiable();
        uint256 vaultTA = IVaultBook(v).totalAssets();
        if (vaultTA == 0) revert Frontier__CapExceeded();
        return (totalAssets() * 10000) / vaultTA;
    }

    /// @dev Call at the top of every supply path, AFTER the idle amount is
    /// known (the amount check runs first so "nothing to supply" is not
    /// masked by gate errors).
    function _frontierGate() internal view {
        if (!venueCleared) revert Frontier__NotCleared();
        if (projectedShareBps() > maxShareBps) revert Frontier__CapExceeded();
    }
}
