// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./tERC20.sol";

/**
 * Note on Balancer work
 *     Due to extra complexity, we fork directly and perform the swaps
 *     This means we are just getting the spot liquidity values
 *     Tests will be less thorough, but they will demonstrate that we can match real values
 */

interface ICompostableFactory {
    function create(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256 amplificationParameter,
        address[] memory rateProviders,
        uint256[] memory tokenRateCacheDurations,
        bool[] memory exemptFromYieldProtocolFeeFlags,
        uint256 swapFeePercentage,
        address owner,
        bytes32 salt
    ) external returns (address);

    enum JoinKind {
        INIT,
        EXACT_TOKENS_IN_FOR_BPT_OUT,
        TOKEN_IN_FOR_EXACT_BPT_OUT,
        ALL_TOKENS_IN_FOR_EXACT_BPT_OUT
    }
}

interface IWeightedPoolFactory {
    function create(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256[] memory normalizedWeights,
        address[] memory rateProviders,
        uint256 swapFeePercentage,
        address owner,
        bytes32 salt
    ) external returns (address);

    enum JoinKind {
        INIT,
        EXACT_TOKENS_IN_FOR_BPT_OUT,
        TOKEN_IN_FOR_EXACT_BPT_OUT,
        ALL_TOKENS_IN_FOR_EXACT_BPT_OUT,
        ADD_TOKEN // for Managed Pool
    }
}
// Token A
// Token B
// Decimal A
// Decimal B
// Amount A
// AmountB
// RateA
// Rate B

// Rate provider for compostable
contract FakeRateProvider {
    uint256 public getRate = 1e18;

    constructor(uint256 newRate) {
        getRate = newRate;
    }
}

interface IPool {
    function getPoolId() external view returns (bytes32);
    function mint(address to) external returns (uint256 liquidity);
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);

    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct BatchSwapStep {
        bytes32 poolId;
        uint256 assetInIndex;
        uint256 assetOutIndex;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    function queryBatchSwap(
        SwapKind kind,
        BatchSwapStep[] memory swaps,
        address[] memory assets, // Note: same encoding
        FundManagement memory funds
    ) external returns (int256[] memory);

    function joinPool(bytes32 poolId, address sender, address recipient, JoinPoolRequest memory request)
        external
        payable;

    struct JoinPoolRequest {
        address[] assets;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }

    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

contract BalancerStable is Test {
    uint256 MAX_BPS = 10_000;

    ICompostableFactory compostableFactory = ICompostableFactory(0xfADa0f4547AB2de89D1304A668C39B3E09Aa7c76);
    IWeightedPoolFactory weightedPoolFactory = IWeightedPoolFactory(0x897888115Ada5773E02aA29F775430BFB5F34c51);
    IPool vault = IPool(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    address owner = address(123);

    function setUp() public {}

    struct TokensAndRates {
        uint256 amountA;
        uint8 decimalsA;
        uint256 amountB;
        uint8 decimalsB;
        uint256 rateA;
        uint256 rateB;
    }

    function _setupStablePool(TokensAndRates memory settings)
        internal
        returns (bytes32 poolId, address firstToken, address secondToken)
    {
        // Deploy 2 mock tokens
        vm.startPrank(owner);
        tERC20 tokenA = new tERC20("A", "A", settings.decimalsA);

        tERC20 tokenB = new tERC20("B", "B", settings.decimalsB);

        address newPool;
        {
            address[] memory tokens = new address[](2);
            tokens[0] = address(tokenA) > address(tokenB) ? address(tokenB) : address(tokenA);
            tokens[1] = address(tokenA) > address(tokenB) ? address(tokenA) : address(tokenB);

            address[] memory rates = new address[](2);
            rates[0] = address(0);
            rates[1] = address(0);

            uint256[] memory durations = new uint256[](2);
            durations[0] = 0;
            durations[1] = 0;

            bool[] memory set = new bool[](2);
            set[0] = false;
            set[1] = false;

            // Deploy new pool
            newPool = compostableFactory.create(
                "Pool",
                "POOL",
                tokens,
                50,
                rates,
                durations,
                set,
                500000000000000,
                address(0xBA1BA1ba1BA1bA1bA1Ba1BA1ba1BA1bA1ba1ba1B),
                bytes32(0xa9b1420213d2145ac43d5d7334c4413d629350bd452d187a766ab8ad3d91ac75)
            );
        }

        poolId = IPool(newPool).getPoolId();

        (address[] memory setupPoolTokens,,) = vault.getPoolTokens(poolId);

        console2.log("setupPoolTokens", setupPoolTokens.length);
        console2.log("setupPoolTokens", setupPoolTokens[0]);
        console2.log("setupPoolTokens", setupPoolTokens[1]);
        console2.log("setupPoolTokens", setupPoolTokens[2]);
        {
            tokenA.approve(address(vault), settings.amountA);
            tokenB.approve(address(vault), settings.amountB);

            address[] memory assets = new address[](3);
            assets[0] = setupPoolTokens[0];
            assets[1] = setupPoolTokens[1];
            assets[2] = setupPoolTokens[2];

            uint256 MAX = 1e18;

            uint256[] memory MAX_AMOUNTS = new uint256[](3);
            MAX_AMOUNTS[0] = type(uint256).max;
            MAX_AMOUNTS[1] = type(uint256).max;
            MAX_AMOUNTS[2] = type(uint256).max;

            uint256[] memory amountsToAdd = new uint256[](3);
            amountsToAdd[0] = setupPoolTokens[0] == address(tokenA)
                ? settings.amountA
                : setupPoolTokens[0] == address(tokenB) ? settings.amountB : MAX;
            console2.log("amountsToAdd[0]", amountsToAdd[0]);

            amountsToAdd[1] = setupPoolTokens[1] == address(tokenA)
                ? settings.amountA
                : setupPoolTokens[1] == address(tokenB) ? settings.amountB : MAX;
            console2.log("amountsToAdd[1]", amountsToAdd[1]);

            amountsToAdd[2] = setupPoolTokens[2] == address(tokenA)
                ? settings.amountA
                : setupPoolTokens[2] == address(tokenB) ? settings.amountB : MAX;
            console2.log("amountsToAdd[2]", amountsToAdd[2]);

            // Abi encode of INIT VALUE
            // [THE 3 AMOUNTS we already wrote]

            // We are pranking owner so this is ok
            vault.joinPool(
                poolId,
                owner,
                owner,
                IPool.JoinPoolRequest(
                    assets, MAX_AMOUNTS, abi.encode(ICompostableFactory.JoinKind.INIT, amountsToAdd), false
                )
            );
        }

        (, uint256[] memory balancesAfterJoin,) = vault.getPoolTokens(poolId);

        for (uint256 i = 0; i < balancesAfterJoin.length; i++) {
            console2.log("balancesAfterJoin stable pool", balancesAfterJoin[i]);
        }

        vm.stopPrank();

        return (poolId, address(tokenA), address(tokenB));
    }

    function _setupWeightedPool(TokensAndRates memory settings)
        internal
        returns (bytes32 poolId, address firstToken, address secondToken)
    {
        // Deploy 2 mock tokens
        vm.startPrank(owner);
        tERC20 tokenA = new tERC20("A", "A", settings.decimalsA);

        tERC20 tokenB = new tERC20("B", "B", settings.decimalsB);

        address newPool;
        {
            address[] memory tokens = new address[](2);
            tokens[0] = address(tokenA) > address(tokenB) ? address(tokenB) : address(tokenA);
            tokens[1] = address(tokenA) > address(tokenB) ? address(tokenA) : address(tokenB);

            address[] memory rates = new address[](2);
            rates[0] = address(0);
            rates[1] = address(0);

            uint256[] memory durations = new uint256[](2);
            durations[0] = 0;
            durations[1] = 0;

            bool[] memory set = new bool[](2);
            set[0] = false;
            set[1] = false;

            uint256[] memory weights = new uint256[](2);
            weights[0] = 5e17;
            weights[1] = 5e17;

            // Deploy new pool
            newPool = weightedPoolFactory.create(
                "Pool",
                "POOL",
                tokens,
                weights,
                rates,
                3000000000000000,
                address(0xBA1BA1ba1BA1bA1bA1Ba1BA1ba1BA1bA1ba1ba1B),
                bytes32(0xa9b1420213d2145ac43d5d7334c4413d629350bd452d187a766ab8ad3d91ac75)
            );
        }

        poolId = IPool(newPool).getPoolId();

        (address[] memory setupPoolTokens,,) = vault.getPoolTokens(poolId);

        console2.log("setupPoolTokens", setupPoolTokens.length);
        console2.log("setupPoolTokens", setupPoolTokens[0]);
        console2.log("setupPoolTokens", setupPoolTokens[1]);
        
        {
            tokenA.approve(address(vault), settings.amountA);
            tokenB.approve(address(vault), settings.amountB);

            address[] memory assets = new address[](2);
            assets[0] = setupPoolTokens[0];
            assets[1] = setupPoolTokens[1];

            uint256 MAX = 1e18;

            uint256[] memory MAX_AMOUNTS = new uint256[](2);
            MAX_AMOUNTS[0] = type(uint256).max;
            MAX_AMOUNTS[1] = type(uint256).max;

            uint256[] memory amountsToAdd = new uint256[](2);
            amountsToAdd[0] = setupPoolTokens[0] == address(tokenA)
                ? settings.amountA
                : setupPoolTokens[0] == address(tokenB) ? settings.amountB : MAX;
            console2.log("amountsToAdd[0]", amountsToAdd[0]);

            amountsToAdd[1] = setupPoolTokens[1] == address(tokenA)
                ? settings.amountA
                : setupPoolTokens[1] == address(tokenB) ? settings.amountB : MAX;
            console2.log("amountsToAdd[1]", amountsToAdd[1]);

            // Abi encode of INIT VALUE
            // [THE 3 AMOUNTS we already wrote]

            // We are pranking owner so this is ok
            // TODO: PROB CHANGE
            vault.joinPool(
                poolId,
                owner,
                owner,
                IPool.JoinPoolRequest(
                    assets, MAX_AMOUNTS, abi.encode(ICompostableFactory.JoinKind.INIT, amountsToAdd), false
                )
            );
        }

        (, uint256[] memory balancesAfterJoin,) = vault.getPoolTokens(poolId);

        for (uint256 i = 0; i < balancesAfterJoin.length; i++) {
            console2.log("balancesAfterJoin Weighted Pool", balancesAfterJoin[i]);
        }

        vm.stopPrank();

        return (poolId, address(tokenA), address(tokenB));
    }

    function test_DAI_R_Compostable() public {
        // Assumption is we always swap
        console2.log("Creating DAI R Pool");

        // TODO: Add verisimilar reserves (use getPoolTokens on real poolId)
        uint256 DAI_BAL = 1063322810377902132666;
        uint256 R_BAL = 1063322810377902132666;

        uint256 WST_ETH_RATE = 1e18;
        uint8 DECIMALS = 18;

        (bytes32 poolId, address WSTETH, address WETH) = _setupStablePool(
            TokensAndRates(
                DAI_BAL,
                DECIMALS,
                R_BAL,
                DECIMALS,
                WST_ETH_RATE,
                DECIMALS // same as rate
            )
        );

        // Let's do amounts and swaps
        // Liquidity for this pair is up to 150 DAI_BAL
        uint256[] memory amountsFromWstETH = new uint256[](5);
        // TODO: Customize these
        amountsFromWstETH[0] = _addDecimals(1, DECIMALS);
        amountsFromWstETH[1] = _addDecimals(10, DECIMALS);
        amountsFromWstETH[2] = _addDecimals(50, DECIMALS);
        amountsFromWstETH[3] = _addDecimals(100, DECIMALS);
        amountsFromWstETH[4] = _addDecimals(150, DECIMALS);

        bytes32 POOL_ID = poolId;

        for (uint256 i; i < amountsFromWstETH.length; i++) {
            uint256 amountIn = amountsFromWstETH[i];
            console2.log("DAI_BAL i", i);
            console2.log("DAI_BAL amountIn (raw)", amountIn);
            uint256 res = _balSwap(POOL_ID, owner, amountIn, WSTETH, WETH);
            console2.log("R_BAL amountOut (raw)", res);
        }
    }

    function test_R_StETH_WeightedPool() public {
        // Assumption is we always swap
        console2.log("Creating R StETH Pool");

        // TODO: Add verisimilar reserves (use getPoolTokens on real poolId)
        uint256 R_BAL = 1063322810377902132666;
        uint256 WST_ETH_BAL = 1063322810377902132666;

        uint256 WST_ETH_RATE = 1e18; // They don't use rates
        uint8 DECIMALS = 18;

        (bytes32 poolId, address WSTETH, address WETH) = _setupWeightedPool(
            TokensAndRates(
                R_BAL,
                DECIMALS,
                WST_ETH_BAL,
                DECIMALS,
                WST_ETH_RATE,
                DECIMALS // same as rate
            )
        );

        // Let's do amounts and swaps
        // Liquidity for this pair is up to 150 WSTETH
        uint256[] memory amountsFromWstETH = new uint256[](5);
        // TODO: Customize these
        amountsFromWstETH[0] = _addDecimals(1, DECIMALS);
        amountsFromWstETH[1] = _addDecimals(10, DECIMALS);
        amountsFromWstETH[2] = _addDecimals(50, DECIMALS);
        amountsFromWstETH[3] = _addDecimals(100, DECIMALS);
        amountsFromWstETH[4] = _addDecimals(150, DECIMALS);

        bytes32 POOL_ID = poolId;

        for (uint256 i; i < amountsFromWstETH.length; i++) {
            uint256 amountIn = amountsFromWstETH[i];
            console2.log("R_BAL i", i);
            console2.log("R_BAL amountIn (raw)", amountIn);
            uint256 res = _balSwap(POOL_ID, owner, amountIn, WSTETH, WETH);
            console2.log("WSTETH amountOut (raw)", res);
        }
    }

    function _balSwap(bytes32 poolId, address user, uint256 amountIn, address tokenIn, address tokenOut)
        internal
        returns (uint256)
    {
        vm.startPrank(user);

        tERC20(tokenIn).approve(address(vault), amountIn);

        IPool.BatchSwapStep[] memory steps = new IPool.BatchSwapStep[](1);
        steps[0] = IPool.BatchSwapStep(
            poolId,
            0,
            1,
            amountIn,
            abi.encode("") // Empty user data
        );

        address[] memory tokens = new address[](2);
        tokens[0] = tokenIn;
        tokens[1] = tokenOut;

        int256[] memory res = vault.queryBatchSwap(
            IPool.SwapKind.GIVEN_IN, steps, tokens, IPool.FundManagement(user, false, payable(user), false)
        );

        vm.stopPrank();

        // Negative means we receive those tokens
        if (res[1] > 0) {
            revert("invalid result");
        }

        return uint256(-res[1]);
    }

    function _addDecimals(uint256 value, uint256 decimals) internal pure returns (uint256) {
        return value * 10 ** decimals;
    }
}
