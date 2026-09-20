// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Mock read-precompiles. The real precompiles take raw ABI-encoded
/// args (no selector) via staticcall; these mocks expose setters for tests and
/// a fallback that returns the canned struct. Copied to the fixed precompile
/// addresses (0x810, 0x813, 0x80f, 0x803, 0x80a, 0x807) via anvil_setCode.

contract MockCoreUserExists {
    bool public exists;

    function setExists(bool e) external {
        exists = e;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(exists);
    }
}

contract MockPosition2 {
    int64 public szi;
    uint64 public entryNtl;
    int64 public isolatedRawUsd;
    uint32 public leverage;
    bool public isIsolated;

    function set(int64 szi_, uint64 entryNtl_, int64 iso_, uint32 lev_, bool isIso_) external {
        szi = szi_;
        entryNtl = entryNtl_;
        isolatedRawUsd = iso_;
        leverage = lev_;
        isIsolated = isIso_;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(szi, entryNtl, isolatedRawUsd, leverage, isIsolated);
    }
}

contract MockMarginSummary {
    int64 public accountValue;
    uint64 public marginUsed;
    uint64 public ntlPos;
    int64 public rawUsd;

    function set(int64 av, uint64 mu, uint64 np, int64 ru) external {
        accountValue = av;
        marginUsed = mu;
        ntlPos = np;
        rawUsd = ru;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(accountValue, marginUsed, ntlPos, rawUsd);
    }
}

contract MockWithdrawable {
    uint64 public amount;

    function setAmount(uint64 a) external {
        amount = a;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(amount);
    }
}

contract MockPerpInfo {
    string public coin;
    uint32 public marginTableId;
    uint8 public szDecimals;
    uint8 public maxLeverage;
    bool public onlyIsolated;

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    function set(string calldata coin_, uint32 mt_, uint8 sz_, uint8 ml_, bool oi_) external {
        coin = coin_;
        marginTableId = mt_;
        szDecimals = sz_;
        maxLeverage = ml_;
        onlyIsolated = oi_;
    }

    // Dynamic struct: the real precompile returns the 1-tuple encoding
    // (offset-wrapped). abi.encode(Struct(...)) mirrors that exactly —
    // direct field encoding would fail the adapter's abi.decode(ret, (Struct)).
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(PerpAssetInfo(coin, marginTableId, szDecimals, maxLeverage, onlyIsolated));
    }
}

contract MockOraclePx {
    uint64 public px;

    function setPx(uint64 p) external {
        px = p;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(px);
    }
}
