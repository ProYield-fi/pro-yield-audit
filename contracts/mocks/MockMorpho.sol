// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho} from "../MorphoStrategy.sol";

interface MockMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Test double for Morpho Blue: share-based supply/withdraw with the
/// real conversion math (shares * totalSupplyAssets / totalSupplyShares),
/// interest simulation via accrue(), and a liquidity switch for the
/// illiquid-market recall path.
contract MockMorpho is IMorpho {
    struct Mkt {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
    }

    mapping(bytes32 => Mkt) public mkts;
    mapping(bytes32 => mapping(address => uint256)) public sharesOf;
    mapping(bytes32 => address) public loanOf;
    bool public illiquid;

    function _id(MarketParams memory mp) internal pure returns (bytes32) {
        return keccak256(abi.encode(mp.loanToken, mp.collateralToken, mp.oracle, mp.irm, mp.lltv));
    }

    function supply(MarketParams memory mp, uint256 assets, uint256, address onBehalf, bytes calldata)
        external
        returns (uint256, uint256)
    {
        IERC20(mp.loanToken).transferFrom(msg.sender, address(this), assets);
        bytes32 id = _id(mp);
        loanOf[id] = mp.loanToken;
        Mkt storage m = mkts[id];
        uint256 sharesOut = m.totalSupplyAssets == 0
            ? assets
            : (assets * m.totalSupplyShares) / m.totalSupplyAssets;
        m.totalSupplyAssets += uint128(assets);
        m.totalSupplyShares += uint128(sharesOut);
        sharesOf[id][onBehalf] += sharesOut;
        return (assets, sharesOut);
    }

    function withdraw(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        bytes32 id = _id(mp);
        Mkt storage m = mkts[id];
        require(m.totalSupplyShares > 0, "mock: no supply");
        uint256 sharesOut = shares > 0
            ? shares
            : (assets * m.totalSupplyShares + m.totalSupplyAssets - 1) / m.totalSupplyAssets;
        if (sharesOut > sharesOf[id][onBehalf]) sharesOut = sharesOf[id][onBehalf];
        uint256 assetsOut = (sharesOut * m.totalSupplyAssets) / m.totalSupplyShares;
        uint256 available = m.totalSupplyAssets - m.totalBorrowAssets;
        require(!illiquid && assetsOut <= available, "mock: illiquid");
        sharesOf[id][onBehalf] -= sharesOut;
        m.totalSupplyShares -= uint128(sharesOut);
        m.totalSupplyAssets -= uint128(assetsOut);
        IERC20(mp.loanToken).transfer(receiver, assetsOut);
        return (assetsOut, sharesOut);
    }

    function position(bytes32 id, address user) external view returns (uint256, uint128, uint128) {
        return (sharesOf[id][user], 0, 0);
    }

    function market(bytes32 id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        Mkt memory m = mkts[id];
        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, uint128(block.timestamp), 0);
    }

    /// @notice Simulate borrower interest: the interest arrives as REAL loan
    /// tokens (minted to the market) and the share price rises.
    function accrue(bytes32 id, uint256 amount) external {
        mkts[id].totalSupplyAssets += uint128(amount);
        MockMintable(loanOf[id]).mint(address(this), amount);
    }

    /// @notice Simulate utilization: assets "borrowed" are not withdrawable.
    function setBorrowed(bytes32 id, uint256 amount) external {
        mkts[id].totalBorrowAssets = uint128(amount);
    }

    function setIlliquid(bool v) external {
        illiquid = v;
    }
}
