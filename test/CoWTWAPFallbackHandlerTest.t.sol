// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {IERC165} from "safe/interfaces/IERC165.sol";
import {ERC721TokenReceiver} from "safe/interfaces/ERC721TokenReceiver.sol";
import {ERC777TokensRecipient} from "safe/interfaces/ERC777TokensRecipient.sol";
import {ERC1155TokenReceiver} from "safe/interfaces/ERC1155TokenReceiver.sol";
import {CompatibilityFallbackHandler} from "safe/handler/CompatibilityFallbackHandler.sol";
import {GnosisSafe} from "safe/GnosisSafe.sol";

import {GPv2EIP1271} from "cowprotocol/interfaces/GPv2EIP1271.sol";
import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

import {ConditionalOrder} from "../src/interfaces/ConditionalOrder.sol";
import {TWAPOrder} from "../src/libraries/TWAPOrder.sol";
import {TWAPOrderMathLib} from "../src/libraries/TWAPOrderMathLib.sol";
import {CoWTWAPFallbackHandler} from "../src/CoWTWAPFallbackHandler.sol";

import "./Base.t.sol";

uint256 constant SELL_AMOUNT = 24000e18;
uint256 constant LIMIT_PRICE = 100e18;
uint32 constant FREQUENCY = 1 hours;
uint32 constant NUM_PARTS = 24;

contract CoWTWAP is Base {
    using SafeCast for uint256;

    event ConditionalOrderCreated(address indexed, bytes);

    CoWTWAPFallbackHandler twapSingleton;
    CoWTWAPFallbackHandler twapSafeWithOrder;
    CoWTWAPFallbackHandler twapSafe;

    TWAPOrder.Data defaultBundle;
    bytes32 defaultBundleHash;
    bytes defaultBundleBytes;

    mapping(bytes32 => uint256) public orderFills;

    function setUp() public virtual override(Base) {
        super.setUp();

        // deploy the CoW TWAP fallback handler
        twapSingleton = new CoWTWAPFallbackHandler(settlement);

        // enable the CoW TWAP fallback handler for safe 1
        setFallbackHandler(safe1, twapSingleton);
        twapSafeWithOrder = CoWTWAPFallbackHandler(address(safe1));

        // enable the CoW TWAP fallback handler for safe 3
        setFallbackHandler(safe3, twapSingleton);
        twapSafe = CoWTWAPFallbackHandler(address(safe3));

        // Set a default bundle
        defaultBundle = _twapTestBundle(block.timestamp + 1 days);
        defaultBundleBytes = abi.encode(defaultBundle);

        deal(address(token0), address(twapSafeWithOrder), SELL_AMOUNT);

        createOrder(
            GnosisSafe(payable(address(twapSafeWithOrder))),
            defaultBundleBytes,
            defaultBundle.sellToken,
            defaultBundle.partSellAmount * defaultBundle.n
        );
    }

    function test_SetUpState_CoWTWAPFallbackHandler_is_set() public {
        // check that the fallback handler is set
        // get the storage at 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5
        // which is the storage slot of the fallback handler
        assertEq(
            vm.load(address(safe1), 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5),
            bytes32(uint256(uint160(address(twapSingleton))))
        );
    }

    /// @dev An end to end test that sets the fallback handler on a Safe and then
    ///      checks that the fallback handler is set correctly checking expected functionality
    ///      from Compatability fallback handler.
    ///      Make use of safe2 to illustrate that the fallback handler can be set on an arbitrary Safe.
    function test_e2e_setFallbackHandler() public {
        // Check to make sure that the default fallback handler is set
        assertEq(
            vm.load(address(safe2), 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5),
            bytes32(uint256(uint160(address(handler))))
        );

        assertTrue(CompatibilityFallbackHandler(address(safe2)).supportsInterface(type(IERC165).interfaceId));
        assertTrue(CompatibilityFallbackHandler(address(safe2)).supportsInterface(type(ERC721TokenReceiver).interfaceId));
        assertTrue(CompatibilityFallbackHandler(address(safe2)).supportsInterface(type(ERC1155TokenReceiver).interfaceId));

        // set the fallback handler to the CoW TWAP fallback handler
        setFallbackHandler(safe2, twapSingleton);

        // check that the fallback handler is set
        // get the storage at 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5
        // which is the storage slot of the fallback handler
        assertEq(
            vm.load(address(safe2), 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5),
            bytes32(uint256(uint160(address(twapSingleton))))
        );

        // check some of the standard interfaces that the fallback handler supports
        CoWTWAPFallbackHandler _safe = CoWTWAPFallbackHandler(address(safe2));
        assertTrue(_safe.supportsInterface(type(IERC165).interfaceId));
        assertTrue(_safe.supportsInterface(type(ERC721TokenReceiver).interfaceId));
        assertTrue(_safe.supportsInterface(type(ERC1155TokenReceiver).interfaceId));
    }

    function test_inherited_CompatibilityFallbackHandler_supportsInterface() public {
        // check some of the standard interfaces that the fallback handler supports
        assertTrue(twapSafeWithOrder.supportsInterface(type(IERC165).interfaceId));
    }

    /// @dev Test inherited functionality from CompatibilityFallbackHandler
    function test_inherited_CompatibilityFallbackHandler_isValidSignature() public {
        // Get a message hash to sign
        bytes32 _msg = keccak256(bytes("Cows are cool"));
        bytes32 msgDigest = twapSafeWithOrder.getMessageHash(abi.encode(_msg));

        // Sign the message
        TestAccount[] memory signers = signers();
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = TestAccountLib.signPacked(signers[0], msgDigest);
        signatures[1] = TestAccountLib.signPacked(signers[1], msgDigest);

        // concatenate the signatures
        bytes memory sigs = abi.encodePacked(signatures[0], signatures[1]);

        // Check that the signature is valid
        assertTrue(twapSafeWithOrder.isValidSignature(_msg, sigs) == bytes4(GPv2EIP1271.MAGICVALUE));
    }

    function test_inherited_CompatibilityFallbackHandler_isValidSignature_RevertWhenNotValidSignature() public {
        // Get a message hash to sign
        bytes32 _msg = keccak256(bytes("Cows are cool"));
        bytes32 msgDigest = twapSafeWithOrder.getMessageHash(abi.encode(_msg));

        // Sign the message
        TestAccount[] memory signers = signers();
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = TestAccountLib.signPacked(signers[0], msgDigest);
        signatures[1] = TestAccountLib.signPacked(signers[1], msgDigest);

        // concatenate the signatures
        bytes memory sigs = abi.encodePacked(signatures[0], signatures[1]);

        // Check that the signature is valid
        assertTrue(twapSafeWithOrder.isValidSignature(_msg, sigs) == bytes4(GPv2EIP1271.MAGICVALUE));

        // Revert when not valid signature because Safe doesn't properly implement EIP1271
        // ie. it reverts instead of returning != bytes4(GPv2EIP1271.MAGICVALUE)
        bytes memory invalidSigs = abi.encodePacked(signatures[0], signatures[0]);
        vm.expectRevert();
        assertTrue(twapSafeWithOrder.isValidSignature(_msg, invalidSigs) != bytes4(GPv2EIP1271.MAGICVALUE));
    }

    function test_inherited_CompatibilityFallbackHandler_isValidSignature_RevertOnMalformedTWAP() public {
        // Generate a malformed TWAP, ie. random bytes of length 288
        bytes memory malformedTWAP = new bytes(288);
        for (uint256 i = 0; i < malformedTWAP.length; i++) {
            malformedTWAP[i] = bytes1(uint8(uint256(keccak256(abi.encodePacked(i))) % 256));
        }

        // Generate a malformed hash
        bytes32 malformedHash = keccak256(malformedTWAP);

        // Revert when not valid signature because Safe doesn't properly implement EIP1271
        // ie. it reverts instead of returning != bytes4(GPv2EIP1271.MAGICVALUE)
        vm.expectRevert();
        assertTrue(twapSafeWithOrder.isValidSignature(malformedHash, malformedTWAP) != bytes4(GPv2EIP1271.MAGICVALUE));
    }

    /// @dev Test creating a TWAP order (event emission)
    ///      A valid order has the following properties:
    ///      - The order is signed by the safe
    ///      - The order is not cancelled
    function testCreateTWAPOrder() public {
        /// @dev We use a new Safe for this test to illustrate that the fallback
        /// handler can be set on an arbitrary Safe.
        setFallbackHandler(safe2, twapSingleton);
        CoWTWAPFallbackHandler _twapSafe = CoWTWAPFallbackHandler(address(safe2));

        TWAPOrder.Data memory order = _twapTestBundle(block.timestamp);
        bytes memory orderBytes = abi.encode(order);

        // this should emit a ConditionalOrderCreated event
        vm.expectEmit(true, true, true, false);
        emit ConditionalOrderCreated(address(_twapSafe), orderBytes);

        // Everything here happens in a batch
        createOrder(GnosisSafe(payable(address(_twapSafe))), orderBytes, order.sellToken, order.partSellAmount * order.n);

        // Check that the order signed by the safe.
        bytes32 orderDigest = ConditionalOrderLib.hash(orderBytes, settlement.domainSeparator());
        assertTrue(_twapSafe.isValidSignature(orderDigest, "") == bytes4(GPv2EIP1271.MAGICVALUE));

        // Check that the order is not cancelled
        bytes32 cancelDigest = ConditionalOrderLib.hashCancel(orderDigest, settlement.domainSeparator());
        vm.expectRevert(bytes("Hash not approved"));
        _twapSafe.isValidSignature(cancelDigest, "");
    }

    function testOrderMustBeSignedBySafe() public {
        /// @dev We use a new Safe for this test to illustrate that the fallback
        /// handler can be set on an arbitrary Safe.
        setFallbackHandler(safe2, twapSingleton);
        CoWTWAPFallbackHandler _twapSafe = CoWTWAPFallbackHandler(address(safe2));

        // Use the default bundle for testing
        vm.warp(defaultBundle.t0);

        // Try get a tradeable order
        vm.expectRevert(ConditionalOrder.OrderNotSigned.selector);
        _twapSafe.getTradeableOrder(defaultBundleBytes);

        // Try to dispatch an order (should fail because the order is not signed)
        vm.expectRevert(ConditionalOrder.OrderNotSigned.selector);
        _twapSafe.dispatch(defaultBundleBytes);

        // Retrieve a valid order from another safe and try to use it
        GPv2Order.Data memory part = twapSafeWithOrder.getTradeableOrder(defaultBundleBytes);
        bytes32 partDigest = GPv2Order.hash(part, settlement.domainSeparator());
        vm.expectRevert(bytes("GS022"));
        _twapSafe.isValidSignature(partDigest, defaultBundleBytes);
    }

    /// @dev Test cancelling a TWAP order
    ///      A cancelled order has the following properties:
    ///      - A cancel order message is signed by the safe
    function testCancelTWAPOrder() public {
        /// @dev Set block time to the start of the TWAP bundle
        vm.warp(defaultBundle.t0);

        // First check that the order is valid by getting a *part* of the TWAP bundle
        GPv2Order.Data memory part = twapSafeWithOrder.getTradeableOrder(defaultBundleBytes);

        // Check that the order *part* is valid
        bytes32 partDigest = GPv2Order.hash(part, settlement.domainSeparator());
        assertTrue(twapSafeWithOrder.isValidSignature(partDigest, defaultBundleBytes) == bytes4(GPv2EIP1271.MAGICVALUE));

        // Cancel the *TWAP order*
        bytes32 twapDigest = ConditionalOrderLib.hash(defaultBundleBytes, settlement.domainSeparator());
        bytes32 cancelDigest = ConditionalOrderLib.hashCancel(twapDigest, settlement.domainSeparator());
        safeSignMessage(safe1, abi.encode(cancelDigest));

        // Check that the *TWAP order* is cancelled
        twapSafeWithOrder.isValidSignature(cancelDigest, "");

        // Try to get a *part* of the TWAP order
        vm.expectRevert(ConditionalOrder.OrderCancelled.selector);
        twapSafeWithOrder.getTradeableOrder(defaultBundleBytes);

        // Check that the order is not valid
        vm.expectRevert(ConditionalOrder.OrderCancelled.selector);
        twapSafeWithOrder.isValidSignature(partDigest, defaultBundleBytes);
    }

    /// @dev Test that the TWAP order is not valid before the start time
    function testNotValidBefore() public {
        vm.warp(defaultBundle.t0 - 1 seconds);
        vm.expectRevert(ConditionalOrder.OrderNotValid.selector);

        // attempt to get a part of the TWAP bundle
        twapSafeWithOrder.getTradeableOrder(defaultBundleBytes);
    }

    /// @dev Test that the TWAP order is not valid after the end time
    ///      This test is a bit tricky because the TWAP order is valid for
    ///      `n` periods of length `t` starting at time `t0`. The order is
    ///      valid for the entire period, so the order is valid until
    ///      `t0 + n * t` exclusive.
    function testNotValidAfter() public {
        vm.warp(defaultBundle.t0 + (defaultBundle.n * defaultBundle.t));
        vm.expectRevert(ConditionalOrder.OrderExpired.selector);

        // get a part of the TWAP bundle
        twapSafeWithOrder.getTradeableOrder(defaultBundleBytes);
    }

    function testNotValidAfterSpan() public {
        vm.warp(defaultBundle.t0 + defaultBundle.span);
        vm.expectRevert(ConditionalOrder.OrderNotValid.selector);

        // attempt to get a part of the TWAP bundle
        twapSafeWithOrder.getTradeableOrder(defaultBundleBytes);
    }

    /// @dev Simulate the TWAP order by iterating over every second and checking
    ///      that the number of parts is correct.
    function testSimulateTWAP() public {
        uint256 totalFills;
        uint256 numSecondsProcessed;

        vm.warp(defaultBundle.t0);

        while (true) {
            try twapSafeWithOrder.getTradeableOrder(defaultBundleBytes) returns (GPv2Order.Data memory order) {
                bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());
                if (
                    orderFills[orderDigest] == 0
                        && twapSafeWithOrder.isValidSignature(orderDigest, defaultBundleBytes) == GPv2EIP1271.MAGICVALUE
                ) {
                    orderFills[orderDigest] = 1;
                    totalFills++;
                }

                // only count this second if we didn't revert
                numSecondsProcessed++;
            } catch (bytes memory lowLevelData) {
                bytes4 desiredSelector = bytes4(keccak256(bytes("OrderExpired()")));
                bytes4 receivedSelector = bytes4(lowLevelData);
                if (receivedSelector == desiredSelector) {
                    break;
                }
            }
            vm.warp(block.timestamp + 1 seconds);
        }

        // the timestamp should be equal to the end time of the TWAP order
        assertTrue(block.timestamp == defaultBundle.t0 + defaultBundle.n * defaultBundle.t);
        // the number of seconds processed should be equal to the number of
        // parts times span (if span is not 0)
        assertTrue(numSecondsProcessed == defaultBundle.n * defaultBundle.span);
        // the number of fills should be equal to the number of parts
        assertTrue(totalFills == defaultBundle.n);
    }

    /// @dev Simulate the TWAP order with a span of 0
    function testSimulateTWAPNoSpan() public {
        TWAPOrder.Data memory noSpanBundle = _twapTestBundle(block.timestamp + 10 days);
        noSpanBundle.n = NUM_PARTS / 2;
        noSpanBundle.t = FREQUENCY / 2;
        noSpanBundle.span = 0;
        bytes memory noSpanBundleBytes = abi.encode(noSpanBundle);

        // create the TWAP order
        createOrder(
            GnosisSafe(payable(address(twapSafeWithOrder))),
            noSpanBundleBytes,
            noSpanBundle.sellToken,
            noSpanBundle.partSellAmount * noSpanBundle.n
        );

        uint256 totalFills;
        uint256 numSecondsProcessed;

        vm.warp(noSpanBundle.t0);

        while (true) {
            try twapSafeWithOrder.getTradeableOrder(noSpanBundleBytes) returns (GPv2Order.Data memory order) {
                bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());
                if (
                    orderFills[orderDigest] == 0
                        && twapSafeWithOrder.isValidSignature(orderDigest, noSpanBundleBytes) == GPv2EIP1271.MAGICVALUE
                ) {
                    orderFills[orderDigest] = 1;
                    totalFills++;
                }
                // only count this second if we didn't revert
                numSecondsProcessed++;
            } catch (bytes memory lowLevelData) {
                bytes4 failedSelected = bytes4(keccak256(bytes("OrderNotValid()")));
                bytes4 desiredSelector = bytes4(keccak256(bytes("OrderExpired()")));
                bytes4 receivedSelector = bytes4(lowLevelData);

                // The order should always be valid because there is no span
                if (receivedSelector == failedSelected) {
                    revert("OrderNotValid() should not be thrown");
                }

                // The order should expire after the last period
                if (receivedSelector == desiredSelector) {
                    break;
                }
                revert();
            }
            vm.warp(block.timestamp + 1 seconds);
        }
        // the timestamp should be equal to the end time of the TWAP order
        assertTrue(block.timestamp == noSpanBundle.t0 + noSpanBundle.n * noSpanBundle.t);
        // the number of seconds processed should be equal to the number of
        // parts times span (if span is not 0)
        assertTrue(numSecondsProcessed == noSpanBundle.n * noSpanBundle.t);
        // the number of fills should be equal to the number of parts
        assertTrue(totalFills == noSpanBundle.n);
    }

    /// @dev Fuzz test `calculateValidTo` function
    /// @param currentTime The current time
    /// @param startTime The start time of the TWAP order
    /// @param numParts The number of parts in the TWAP order
    /// @param frequency The frequency of the TWAP order
    /// @param span The span of the TWAP order
    function testCalculateValidTo(
        uint256 currentTime,
        uint256 startTime,
        uint256 numParts,
        uint256 frequency,
        uint256 span
    ) public {
        // --- Implicit assumptions
        // currentTime is always set to the current block timestamp in the TWAP order, so we can assume that it is less
        // than the max uint32 value.
        vm.assume(currentTime <= type(uint32).max);

        // --- Assertions
        // number of parts is asserted to be less than the max uint32 value in the TWAP order, so we can assume that it is
        // less than the max uint32 value.
        numParts = bound(numParts, 2, type(uint32).max);

        // frequency is asserted to be less than 365 days worth of seconds in the TWAP order, and at least 1 second
        vm.assume(frequency >= 1 && frequency <= 365 days);

        // The span is defined as the number of seconds that the TWAP order is valid for within each period. If the span
        // is 0, then the TWAP order is valid for the entire period. We can assume that the span is less than or equal
        // to the frequency.
        vm.assume(span <= frequency);

        // --- In-function revert conditions
        // We only calculate `validTo` if we are within the TWAP order's time window, so we can assume that the current
        // time is greater than or equal to the start time.
        vm.assume(currentTime >= startTime);

        // The TWAP order is deemed expired if the current time is greater than the end time of the last part. We can
        // assume that the current time is less than the end time of the TWAP order.
        vm.assume(currentTime < startTime + (numParts * frequency));

        uint256 part = (currentTime - startTime) / frequency;

        // The TWAP order is only valid for the span within each period, so we can assume that the current time is less
        // than the end time of the current part.
        vm.assume(currentTime < startTime + ((part + 1) * frequency) - (span != 0 ? (frequency - span) : 0));

        // --- Warp to the current time
        vm.warp(currentTime);

        uint256 validTo = TWAPOrderMathLib.calculateValidTo(startTime, numParts, frequency, span);

        uint256 expectedValidTo = startTime + ((part + 1) * frequency) - (span != 0 ? (frequency - span) : 0) - 1;

        // `validTo` MUST be now or in the future.
        assertTrue(validTo >= currentTime);
        // `validTo` MUST be equal to this.
        assertTrue(validTo == expectedValidTo);
    }

    function _twapTestBundle(uint256 startTime) internal view returns (TWAPOrder.Data memory) {
        return TWAPOrder.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0), // the safe itself
            partSellAmount: SELL_AMOUNT / NUM_PARTS,
            minPartLimit: LIMIT_PRICE,
            t0: startTime.toUint32(),
            n: NUM_PARTS,
            t: 1 hours,
            span: 5 minutes
        });
    }
}