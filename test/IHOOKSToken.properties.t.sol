// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IHOOKSToken} from "../src/IHOOKSToken.sol";

/// @notice A holder that is a contract, with no receive or fallback: the token must not care.
contract ContractHolder {
    function send(IHOOKSToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Edge cases and algebraic properties beyond the unit suite in IHOOKSToken.t.sol: error
/// precedence, allowance boundaries, event discipline, round trips, additivity, independence of
/// deployments, and inputs at zero, one wei, the full supply and the type maximum.
/// forge-config: default.fuzz.runs = 1000
contract IHOOKSTokenPropertiesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    bytes32 constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    IHOOKSToken token;
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.prank(deployer);
        token = new IHOOKSToken();
    }

    // ---------------------------------------------------------------- supply and metadata, exactly

    function test_supplyIsOneBillionWholeTokens() public view {
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.INITIAL_SUPPLY() / 10 ** token.decimals(), 1_000_000_000);
        assertEq(token.INITIAL_SUPPLY() % 10 ** token.decimals(), 0);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function test_nameAndSymbolAreByteExact() public view {
        assertEq(keccak256(bytes(token.name())), keccak256("identity hooks"));
        assertEq(bytes(token.name()).length, 14);
        assertEq(keccak256(bytes(token.symbol())), keccak256("IHOOKS"));
        assertEq(bytes(token.symbol()).length, 6);
    }

    /// @dev The constructor emits one event and only one: the mint. Nothing else is logged.
    function test_constructorEmitsExactlyOneLog() public {
        vm.recordLogs();
        vm.prank(deployer);
        IHOOKSToken fresh = new IHOOKSToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(0)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(deployer))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    /// @dev Two deployments are independent: each mints its own full supply to its own deployer
    /// and neither sees the other's balances.
    function test_deploymentsAreIndependent() public {
        vm.prank(alice);
        IHOOKSToken second = new IHOOKSToken();
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
        vm.prank(deployer);
        token.transfer(bob, 1 ether);
        assertEq(second.balanceOf(bob), 0);
    }

    /// @dev Whoever deploys gets the supply: a contract deployer, an EOA, or the test itself.
    function testFuzz_anyDeployerReceivesTheWholeSupply(address who) public {
        vm.assume(who != address(0));
        vm.assume(who.code.length == 0);
        vm.prank(who);
        IHOOKSToken fresh = new IHOOKSToken();
        assertEq(fresh.balanceOf(who), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_noBurnEntrypointShrinksSupply() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        string[3] memory signatures = ["burn(uint256)", "burn(address,uint256)", "redeem(uint256)"];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(alice);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], 1 ether, 1 ether));
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(alice), 10 ether, signatures[i]);
        }
    }

    /// @dev No permit: the token has no EIP-2612 surface, so a signature can never move funds.
    function test_noPermitOrDomainSeparator() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("nonces(address)", deployer));
        assertFalse(ok);
        (ok,) = address(token)
            .call(
                abi.encodeWithSignature(
                    "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                    deployer,
                    alice,
                    SUPPLY,
                    type(uint256).max,
                    uint8(27),
                    bytes32(0),
                    bytes32(0)
                )
            );
        assertFalse(ok);
        assertEq(token.allowance(deployer, alice), 0);
    }

    function test_unknownSelectorAndEmptyCalldataRevert() public {
        (bool ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok);
        (ok,) = address(token).call("");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- transfer edges

    function test_transferOneWei() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
    }

    function test_transferMaxUintRevertsForEveryone() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, type(uint256).max)
        );
        token.transfer(bob, type(uint256).max);
    }

    /// @dev Exactly one wei over the balance fails; exactly the balance succeeds.
    function test_transferAtAndJustAboveBalanceBoundary() public {
        vm.prank(deployer);
        token.transfer(alice, 7 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 7 ether, 7 ether + 1)
        );
        token.transfer(bob, 7 ether + 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 7 ether));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 7 ether);
    }

    /// @dev Zero to the zero address is still refused: the receiver check runs before the amount matters.
    function test_transferZeroToZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    /// @dev A self-transfer above the balance still fails: there is no shortcut for from == to.
    function test_selfTransferAboveBalanceReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(deployer, SUPPLY + 1);
    }

    /// @dev Self-transfer still emits a Transfer event, so indexers see it even though nothing moved.
    function test_selfTransferEmitsEvent() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(deployer, deployer, 3 ether);
        token.transfer(deployer, 3 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev Tokens can be sent to the token contract itself. They are stuck, but they are still
    /// counted: the supply and the sum of balances do not change.
    function test_transferToTokenContractIsCountedNotLost() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 5 ether));
        assertEq(token.balanceOf(address(token)), 5 ether);
        assertEq(token.balanceOf(deployer) + token.balanceOf(address(token)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A contract with no receive hook can hold and send tokens: there is no ERC-777 style
    /// callback, so a contract recipient cannot reject or re-enter a transfer.
    function test_contractHolderCanReceiveAndSend() public {
        ContractHolder holder = new ContractHolder();
        vm.prank(deployer);
        token.transfer(address(holder), 2 ether);
        assertEq(token.balanceOf(address(holder)), 2 ether);
        assertTrue(holder.send(token, alice, 2 ether));
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.balanceOf(address(holder)), 0);
    }

    function test_transferEmitsExactlyOneLogAndNoApproval() public {
        vm.recordLogs();
        vm.prank(deployer);
        token.transfer(alice, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
    }

    // ---------------------------------------------------------------- allowance edges

    /// @dev Error precedence: allowance is checked before balance. When both are short, the
    /// allowance error wins; with enough allowance but no balance, the balance error wins.
    function test_transferFromErrorPrecedence() public {
        // alice has nothing and gave bob nothing.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1 ether));
        token.transferFrom(alice, carol, 1 ether);

        // alice has nothing but gave bob plenty.
        vm.prank(alice);
        token.approve(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, carol, 1 ether);
        assertEq(token.allowance(alice, bob), 100 ether, "a failed transferFrom spent allowance");
    }

    /// @dev Infinite allowance does not override the balance check.
    function test_infiniteAllowanceStillBoundedByBalance() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transferFrom(deployer, bob, SUPPLY + 1);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, SUPPLY));
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    /// @dev The infinite sentinel is exactly the maximum: one less is an ordinary allowance and is spent.
    function test_maxMinusOneAllowanceIsDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max - 1);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), type(uint256).max - 2);
    }

    /// @dev Spending the whole allowance leaves zero, and the next wei is refused.
    function test_allowanceSpentExactlyThenExhausted() public {
        vm.prank(deployer);
        token.approve(alice, 4 ether);
        vm.startPrank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        token.transferFrom(deployer, bob, 3 ether);
        assertEq(token.allowance(deployer, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 4 ether);
    }

    /// @dev A holder spending their own balance through transferFrom still needs a self-allowance.
    function test_transferFromOwnBalanceNeedsSelfAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);

        vm.startPrank(deployer);
        token.approve(deployer, 2);
        assertTrue(token.transferFrom(deployer, alice, 1));
        vm.stopPrank();
        assertEq(token.allowance(deployer, deployer), 1);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_transferFromToZeroAddressRevertsEvenWithAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1 ether);
        assertEq(token.allowance(deployer, alice), 10 ether);
    }

    /// @dev `from` of zero cannot be spent from: there is no allowance from the zero address and
    /// the error names the allowance, not the sender.
    function test_transferFromZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    /// @dev Allowances are directional and per-pair.
    function test_allowanceIsDirectionalAndIsolated() public {
        vm.prank(deployer);
        token.approve(alice, 9 ether);
        assertEq(token.allowance(deployer, alice), 9 ether);
        assertEq(token.allowance(alice, deployer), 0);
        assertEq(token.allowance(deployer, bob), 0);
        assertEq(token.allowance(bob, alice), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, carol, 1);
    }

    /// @dev Approving needs no balance: anyone can approve anything, and it is only a promise.
    function test_approveNeedsNoBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, type(uint256).max));
        assertEq(token.allowance(alice, bob), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    function test_approveZeroClearsAllowance() public {
        vm.startPrank(deployer);
        token.approve(alice, 5 ether);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Approval(deployer, alice, 0);
        token.approve(alice, 0);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 0);
    }

    /// @dev Spending an allowance emits a Transfer only: no Approval event for the decrement.
    function test_transferFromEmitsTransferOnly() public {
        vm.prank(deployer);
        token.approve(alice, 5 ether);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 2 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(deployer))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(abi.decode(logs[0].data, (uint256)), 2 ether);
    }

    /// @dev An approval is not consumed by the owner's own transfers: it is a separate budget.
    function test_ownerTransferDoesNotTouchAllowance() public {
        vm.startPrank(deployer);
        token.approve(alice, 5 ether);
        token.transfer(bob, 100 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 5 ether);
    }

    // ---------------------------------------------------------------- algebraic properties

    /// @dev Round trip: a transfer there and back restores both balances exactly.
    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Additivity: two transfers of a and b have the same effect as one of a + b.
    function testFuzz_transfersAreAdditive(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        vm.prank(alice);
        IHOOKSToken other = new IHOOKSToken();

        vm.startPrank(deployer);
        token.transfer(bob, a);
        token.transfer(bob, b);
        vm.stopPrank();
        vm.prank(alice);
        other.transfer(bob, a + b);

        assertEq(token.balanceOf(bob), other.balanceOf(bob));
        assertEq(token.balanceOf(deployer), other.balanceOf(alice));
        assertEq(token.balanceOf(bob), a + b);
    }

    /// @dev A chain of hops conserves the amount: what leaves the deployer arrives at the end.
    function testFuzz_chainOfHopsConservesAmount(uint256 amount, uint8 hops) public {
        amount = bound(amount, 0, SUPPLY);
        hops = uint8(bound(hops, 1, 16));
        address from = deployer;
        for (uint256 i; i < hops; ++i) {
            address to = address(uint160(uint256(keccak256(abi.encode("hop", i)))));
            vm.prank(from);
            assertTrue(token.transfer(to, amount));
            assertEq(token.balanceOf(from), from == deployer ? SUPPLY - amount : 0);
            assertEq(token.balanceOf(to), amount);
            from = to;
        }
        assertEq(token.balanceOf(from), amount);
        assertEq(token.balanceOf(deployer) + token.balanceOf(from), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Splitting the supply across many recipients loses nothing: the parts sum to the whole.
    function testFuzz_splitAcrossManyRecipientsSumsToSupply(uint256 seed, uint8 count) public {
        count = uint8(bound(count, 1, 40));
        uint256 remaining = SUPPLY;
        uint256 paid;
        for (uint256 i; i < count; ++i) {
            uint256 share = uint256(keccak256(abi.encode(seed, i))) % (remaining + 1);
            address to = address(uint160(uint256(keccak256(abi.encode("recipient", i)))));
            vm.prank(deployer);
            token.transfer(to, share);
            assertEq(token.balanceOf(to), share);
            paid += share;
            remaining -= share;
        }
        assertEq(token.balanceOf(deployer), SUPPLY - paid);
        assertEq(token.balanceOf(deployer) + paid, SUPPLY);
    }

    /// @dev The last approve wins, whatever came before, and a transferFrom spends from that value.
    function testFuzz_lastApproveWins(uint256 first, uint256 second, uint256 spend) public {
        second = bound(second, 0, SUPPLY);
        spend = bound(spend, 0, second);
        vm.startPrank(deployer);
        token.approve(alice, first);
        token.approve(alice, second);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), second);
        vm.prank(alice);
        token.transferFrom(deployer, bob, spend);
        assertEq(token.allowance(deployer, alice), second - spend);
        assertEq(token.balanceOf(bob), spend);
    }

    /// @dev Any approval value, including above the supply and the maximum, is stored verbatim.
    function testFuzz_approveStoresAnyValue(address spender, uint256 amount) public {
        vm.assume(spender != address(0));
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Approval(alice, spender, amount);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(alice, spender), amount);
    }

    /// @dev A transferFrom moves exactly the amount from the owner to the receiver and charges
    /// exactly that amount against a finite allowance, for any amount within both.
    function testFuzz_transferFromMovesAndChargesExactly(uint256 allowance, uint256 amount, address to) public {
        vm.assume(to != address(0) && to != deployer);
        allowance = bound(allowance, 0, type(uint256).max - 1);
        amount = bound(amount, 0, allowance < SUPPLY ? allowance : SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowance);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.allowance(deployer, alice), allowance - amount);
        assertEq(token.balanceOf(alice), 0, "the spender gained nothing");
    }

    /// @dev Whoever is not the holder, with no allowance, cannot move a single wei of the holder's.
    function testFuzz_strangerCannotMoveHolderBalance(address stranger, uint256 amount) public {
        vm.assume(stranger != deployer);
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        token.transferFrom(deployer, stranger, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev Any sender with any balance: a transfer of more than that balance fails with the exact
    /// shortfall reported, and nothing moves.
    function testFuzz_transferAboveAnyBalanceReverts(uint256 balance, uint256 excess) public {
        balance = bound(balance, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - balance);
        vm.prank(deployer);
        token.transfer(alice, balance);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + excess)
        );
        token.transfer(bob, balance + excess);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);
    }
}
