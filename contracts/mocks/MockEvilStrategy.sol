// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "../BaseStrategy.sol";

/// @notice Adversary strategy: during harvest it re-enters the vault's
/// deposit/withdraw to try to corrupt accounting or drain funds.
/// Used ONLY by integration_tests.js to prove the guards hold.
contract MockEvilStrategy is BaseStrategy {
    address public attackerVault; // the ProYieldVault we attack
    bool public attackDeposit;
    bool public attackWithdraw;

    constructor(address _underlying, address initialOwner)
        BaseStrategy(_underlying, initialOwner, "EvilStrategy")
    {}

    function setAttackTarget(address vault_, bool doDeposit, bool doWithdraw) external onlyOwner {
        attackerVault = vault_;
        attackDeposit = doDeposit;
        attackWithdraw = doWithdraw;
    }

    function name() external view override returns (string memory) {
        return "EvilStrategy";
    }

    function _doHarvest() internal override returns (uint256 profit) {
        profit = 0;
        if (attackerVault == address(0)) return 0;
        if (attackDeposit) {
            // reenter deposit with our own underlying (if any)
            uint256 bal = underlying.balanceOf(address(this));
            if (bal > 1000) {
                underlying.approve(attackerVault, bal);
                try ProYieldVaultLike(attackerVault).deposit(bal / 2) {} catch {}
            }
        }
        if (attackWithdraw) {
            // reenter withdraw with our share balance (should be 0 — we never deposited)
            try ProYieldVaultLike(attackerVault).withdraw(1000e18) {} catch {}
        }
    }
}

interface ProYieldVaultLike {
    function deposit(uint256) external;
    function withdraw(uint256) external;
}
