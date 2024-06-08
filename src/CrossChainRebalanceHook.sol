// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {IAcrossBridge} from "./interface/IAcrossBridge.sol";
import {IStargateRouter} from "./interface/IStargateRouter.sol";
import {console} from "forge-std/Test.sol";

contract CrossChainRebalanceHook is Ownable {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    IStargateRouter public immutable stargateRouter;
    IAcrossBridge public immutable acrossBridge;

    mapping(address l1Token => address l2Token) public l1ToL2TokenAddresses;

    struct CallbackData {
        address sender;
        SwapSettings settings;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    struct SwapSettings {
        bool bridgeTokens;
        bool isFirstBridge; // true = acrossbridge & false stargatebridge
        address recipientAddress;
        uint8[] percetages;
        uint8[] chainIds;
        uint8[] poolIds;
        bytes[] destCallData;
    }

    error CallerNotManager();
    error TokenCannotBeBridged();

    constructor(
        IPoolManager _manager,
        IStargateRouter _stargateRouter,
        IAcrossBridge _acrossBridge
    )
        Ownable(msg.sender)
    {
        manager = _manager;
        stargateRouter = _stargateRouter;
        acrossBridge = _acrossBridge;
    }

    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        SwapSettings memory settings,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        if (settings.bridgeTokens) {
            Currency l1TokenToBridge = params.zeroForOne
                ? key.currency1
                : key.currency0;

            if (!l1TokenToBridge.isNative()) {
                address l2Token = l1ToL2TokenAddresses[
                    Currency.unwrap(l1TokenToBridge)
                ];
                if (l2Token == address(0)) revert TokenCannotBeBridged();
            }
        }

        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    CallbackData(msg.sender, settings, key, params, hookData)
                )
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0)
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
    }

    function unlockCallback(
        bytes calldata rawData
    ) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert CallerNotManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        int256 deltaAfter0 = manager.currencyDelta(
            address(this),
            data.key.currency0
        );
        int256 deltaAfter1 = manager.currencyDelta(
            address(this),
            data.key.currency1
        );

        if (deltaAfter0 < 0) {
            console.log("deltaAfter0-1: ", uint256(-deltaAfter0));
            data.key.currency0.settle(
                manager,
                data.sender,
                uint256(-deltaAfter0),
                false
            );
        }

        if (deltaAfter1 < 0) {
            data.key.currency1.settle(
                manager,
                data.sender,
                uint256(-deltaAfter1),
                false
            );
        }

        if (deltaAfter0 > 0) {
            _take(
                data.key.currency0,
                data.settings.recipientAddress,
                uint256(deltaAfter0),
                data.settings
            );
        }

        if (deltaAfter1 > 0) {
            _take(
                data.key.currency1,
                data.settings.recipientAddress,
                uint256(deltaAfter1),
                data.settings
            );
        }

        return abi.encode(delta);
    }

    function _take(
        Currency currency,
        address recipient,
        uint256 amount,
        SwapSettings memory _settings
    ) internal {
        if (!_settings.bridgeTokens) {
            currency.take(manager, recipient, amount, false);
        } else {
            currency.take(manager, address(this), amount, false);

            // if (currency.isNative()) {
            //     // stargateRouter.depositETHTo{value: amount}(recipient, 0, "");
            // } else {
                address l1Token = Currency.unwrap(currency);
                // address l2Token = l1ToL2TokenAddresses[l1Token];
                for (uint i=0; i<_settings.chainIds.length; i++) {
                    if (_settings.isFirstBridge) {
                        console.log("Across");
                        IERC20Minimal(l1Token).approve(address(acrossBridge), amount);
                        acrossBridge.depositV3(
                            recipient, // User's address on the origin chain.
                            recipient, // recipient. Whatever address the user wants to recieve the funds on the destination.
                            l1Token, // inputToken. This is the usdc address on the originChain
                            address(0), // outputToken: 0 address means the output token and input token are the same. Today, no relayers support swapping so the relay will not be filled if this is set to anything other than 0x0.
                            1e6, // inputAmount
                            1e6 - 1e4, // outputAmount: this is the amount - relay fees. totalRelayFee.total is the value returned by the suggested-fees API.
                            10, // destinationChainId
                            address(0), // exclusiveRelayer: set to 0x0 for typical integrations.
                            uint32(block.timestamp), // quoteTimestamp: this should be set to the timestamp returned by the API.
                            uint32(block.timestamp) + 21600, // fillDeadline: We reccomend a fill deadline of 6 hours out. The contract will reject this if it is beyond 8 hours from now.
                            uint32(block.timestamp) + 21600, // exclusivityDeadline: since there's no exclusive relayer, set this to 0.
                            _settings.destCallData[i] // message: empty message since this is just a simple transfer.
                        );
                    } else {
                        console.log("Stargate");
                        IERC20Minimal(l1Token).approve(address(stargateRouter), amount);
                        IStargateRouter.lzTxObj memory _lzTxParams = IStargateRouter
                            .lzTxObj({
                                dstGasForCall: 0,
                                dstNativeAmount: 0,
                                dstNativeAddr: "0x"
                            });
                        stargateRouter.swap{value: 3e18 /** Value is in Matic tokens */}(
                            _settings.chainIds[i],
                            1,
                            _settings.poolIds[i],
                            payable(recipient),
                            1000000,
                            0,
                            _lzTxParams,
                            abi.encodePacked(address(recipient)),
                            _settings.destCallData[i]
                        );
                    }
                }
            // }
        }
    }

    function addL1ToL2TokenAddress(
        address l1Token,
        address l2Token
    ) external onlyOwner {
        l1ToL2TokenAddresses[l1Token] = l2Token;
    }

    receive() external payable {}
}
