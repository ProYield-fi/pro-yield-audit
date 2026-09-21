// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test swapper: tokenIn → PYD at a 1:1 stand-in rate (documented).
/// Production swaps go through the owner-set swapper (HyperEVM AMM or
/// HyperCore spot) — this mock keeps the PYDFunder test venue-independent.
contract MockSwapper {
    IERC20 public immutable pydOut;
    IERC20 public immutable tokenIn;

    constructor(address _pyd, address _tokenIn) {
        pydOut = IERC20(_pyd);
        tokenIn = IERC20(_tokenIn);
    }

    function swap(address tIn, address, uint256 amountIn, uint256) external returns (uint256) {
        // 1:1 by VALUE: production USDC is 6dp, PYD is 18dp — the swapper
        // handles the decimals (6dp in → 18dec out, ×10^12). The funder's
        // balance drains by exactly the swapped input amount.
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 10 ** 12; // 6dp → 18dec (documented stand-in)
        pydOut.transfer(msg.sender, out);
        return out;
    }
}
