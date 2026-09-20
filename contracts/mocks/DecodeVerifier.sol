// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DNCoreStrategy} from "../DNCoreStrategy.sol";

/// @notice Feeds RAW production precompile returns through the exact Solidity
/// decode path used by DNCoreStrategy — verifying the read layer against real
/// mainnet data with zero deployments on HyperEVM (local eth_call only).
contract DecodeVerifier {
    function decodePerpAssetInfo(bytes calldata ret)
        external
        pure
        returns (string memory coin, uint32 marginTableId, uint8 szDecimals, uint8 maxLeverage, bool onlyIsolated)
    {
        DNCoreStrategy.PerpAssetInfo memory info = abi.decode(ret, (DNCoreStrategy.PerpAssetInfo));
        return (info.coin, info.marginTableId, info.szDecimals, info.maxLeverage, info.onlyIsolated);
    }

    function decodePosition(bytes calldata ret)
        external
        pure
        returns (int64 szi, uint64 entryNtl, int64 isolatedRawUsd, uint32 leverage, bool isIsolated)
    {
        DNCoreStrategy.Position memory p = abi.decode(ret, (DNCoreStrategy.Position));
        return (p.szi, p.entryNtl, p.isolatedRawUsd, p.leverage, p.isIsolated);
    }

    function decodeMarginSummary(bytes calldata ret)
        external
        pure
        returns (int64 accountValue, uint64 marginUsed, uint64 ntlPos, int64 rawUsd)
    {
        DNCoreStrategy.AccountMarginSummary memory m = abi.decode(ret, (DNCoreStrategy.AccountMarginSummary));
        return (m.accountValue, m.marginUsed, m.ntlPos, m.rawUsd);
    }

    function decodeUint64(bytes calldata ret) external pure returns (uint64) {
        return abi.decode(ret, (uint64));
    }

    function decodeBool(bytes calldata ret) external pure returns (bool) {
        return abi.decode(ret, (bool));
    }
}
