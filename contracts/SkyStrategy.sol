// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SkyStrategy is BaseStrategy {
    IERC20 public immutable usds;
    uint256 public immutable debtRatio;
    address public immutable skyRegistry;

    constructor(address _underlying, address initialOwner, address _registry)
        BaseStrategy(_underlying, initialOwner, "Sky")
    {
        usds = IERC20(_underlying);
        require(_registry != address(0), "Sky: zero registry");
        skyRegistry = _registry;
        debtRatio = 5000;
    }

    function name() external view override returns (string memory) {
        return "Sky";
    }

    /// @notice Honest harvest: this strategy holds its allocation as USDC and
    /// earns via the (to-be-integrated) Sky adapter. The previous version
    /// moved the strategy's ENTIRE ETH balance to msg.sender and booked it
    /// as `totalDebt` profit — fake accounting + a drain pattern (same class
    /// as the Morpho fake-profit bug). Until the real adapter lands, harvest
    /// returns 0: no principal moves, no debt is fabricated.
    function _doHarvest() internal override returns (uint256) {
        return 0;
    }
}
