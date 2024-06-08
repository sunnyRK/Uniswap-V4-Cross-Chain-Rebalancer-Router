// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {CrossChainRebalanceHook, IStargateRouter, IAcrossBridge} from "../src/CrossChainRebalanceHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract TestCrossChainRebalanceHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    event Swap(
        uint16 chainId,
        uint256 dstPoolId,
        address from,
        uint256 amountSD,
        uint256 eqReward,
        uint256 eqFee,
        uint256 protocolFee,
        uint256 lpFee
    );

    uint256 sepoliaForkId =
        vm.createFork(
            "https://polygon-mainnet.infura.io/v3/<Polygon_INFURA_KEY>" // add your key here
        );

    CrossChainRebalanceHook crossChainRebalanceHook;

    IERC20 USDCPolygon =
        IERC20(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359);
        // IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);

    IERC20 USDCOp =
        IERC20(0x7F5c764cBc14f9669B88837ca1490cCa17c31607);

    IStargateRouter public constant stargateRouter =
        IStargateRouter(0xeCc19E177d24551aA7ed6Bc6FE566eCa726CC8a9);

    IAcrossBridge public constant acrossBridge =
        IAcrossBridge(0x9295ee1d8C5b022Be115A2AD3c30C72E34e7F096);

    bytes public aaveV3DepositDataForOp = "0x617ba0370000000000000000000000007f5c764cbc14f9669b88837ca1490cca17c316070000000000000000000000000000000000000000000000000000000000002710000000000000000000000000b50685c25485ca8c520f5286bbbf1d3f216d69890000000000000000000000000000000000000000000000000000000000000000";

    function setUp() public {
        vm.selectFork(sepoliaForkId);
        vm.deal(address(this), 500 ether);
        vm.deal(address(this), 500 ether);

        // Deploy manager and routers
        deployFreshManagerAndRouters();
        crossChainRebalanceHook = new CrossChainRebalanceHook(
            manager,
            stargateRouter,
            acrossBridge
        );

        deal(address(USDCPolygon), address(this), 1000000 ether);
        USDCPolygon.approve(address(crossChainRebalanceHook), type(uint256).max);
        USDCPolygon.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Create the OUTb token mapping on the periphery contract
        crossChainRebalanceHook.addL1ToL2TokenAddress(
            address(USDCPolygon),
            address(USDCOp)
        );

        // Deploy an ETH <> OUTb pool and add some liquidity there
        (key, ) = initPool(
            CurrencyLibrary.NATIVE,
            Currency.wrap(address(USDCPolygon)),
            IHooks(address(0)),
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );
        console.log("Before: ", USDCPolygon.balanceOf(address(this)));
        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        console.log("After: ", USDCPolygon.balanceOf(address(this)));
    }

    // Polygon Swap ETH to USDC => bridge USDC to OP network and deposit USDC to Op's aave
    function testSwapEthtoUSDC_BridgeViaAcross_DepositAave()
        public
    {
        // vm.expectEmit(true, true, false, false);
        // emit Swap(111, 1, address(stargateRouter), 0, 0, 0, 0, 0);
        uint8[] memory percetages = new uint8[](2);
        percetages[0] = 50;
        percetages[1] = 50;

        uint8[] memory chainIds = new uint8[](2);
        chainIds[0] = 110;
        chainIds[1] = 111;

        uint8[] memory poolIds = new uint8[](2);
        poolIds[0] = 1;
        poolIds[1] = 1;

        bytes[] memory destCallData = new bytes[](2);
        destCallData[0] = aaveV3DepositDataForOp;
        destCallData[1] = aaveV3DepositDataForOp;

        crossChainRebalanceHook.swap{value: 10 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            CrossChainRebalanceHook.SwapSettings({
                bridgeTokens: true,
                recipientAddress: address(this),
                percetages: percetages,
                chainIds: chainIds,
                poolIds: poolIds,
                destCallData: destCallData,
                isFirstBridge: false // true = Across & false = stargate
            }),
            ZERO_BYTES
        );
    }
}