// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Pool.sol";
import "../src/PoolFactory.sol";
import "../src/ShareToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20Sec is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PoolSecurityTest is Test {
    PoolFactory factory;
    Pool pool;
    MockERC20Sec usdc;
    MockERC20Sec collateralToken;

    address admin = address(1);
    address alice = address(2);
    address bob = address(3);
    address attacker = address(99);
    address guardian1 = address(5);
    address guardian2 = address(6);

    function setUp() public {
        usdc = new MockERC20Sec();
        collateralToken = new MockERC20Sec();
        factory = new PoolFactory();

        vm.startPrank(admin);
        
        address[] memory guardians = new address[](2);
        guardians[0] = guardian1;
        guardians[1] = guardian2;

        address poolAddr = factory.createPool(
            "Security Test Pool",
            address(usdc),
            100 * 1e18,
            3 days,
            5000,
            6000,
            2000,
            guardians
        );

        pool = Pool(payable(poolAddr));
        pool.addToWhitelist(alice);
        pool.addToWhitelist(bob);
        pool.addToWhitelist(guardian1);
        pool.addToWhitelist(guardian2);
        vm.stopPrank();

        usdc.mint(alice, 10000 * 1e18);
        usdc.mint(bob, 10000 * 1e18);
        usdc.mint(attacker, 10000 * 1e18);
        usdc.mint(guardian1, 1000 * 1e18);
        usdc.mint(guardian2, 1000 * 1e18);
    }

    // ============ Access Control Tests ============

    function test_RevertWhen_NonAdminWhitelists() public {
        vm.prank(alice);
        vm.expectRevert(Pool.NotAdmin.selector);
        pool.addToWhitelist(attacker);
    }

    function test_RevertWhen_NonAdminAddsGuardian() public {
        vm.prank(alice);
        vm.expectRevert(Pool.NotAdmin.selector);
        pool.addGuardian(attacker);
    }

    function test_RevertWhen_NonGuardianApproves() public {
        _setupPoolAndRequest();
        
        vm.prank(alice);
        vm.expectRevert(Pool.NotGuardian.selector);
        pool.guardianApprove(0);
    }

    function test_RevertWhen_NonMemberWithdraws() public {
        vm.prank(attacker);
        vm.expectRevert(Pool.NotMember.selector);
        pool.withdraw(100 * 1e18);
    }

    function test_RevertWhen_NonMemberVotes() public {
        _setupPoolAndRequest();
        
        vm.prank(attacker);
        vm.expectRevert(Pool.NotMember.selector);
        pool.vote(0, true);
    }

    // ============ Double Action Tests ============

    function test_RevertWhen_DoubleVote() public {
        _setupPoolAndRequest();

        vm.startPrank(alice);
        pool.vote(0, true);
        
        vm.expectRevert(Pool.AlreadyVoted.selector);
        pool.vote(0, true);
        vm.stopPrank();
    }

    function test_RevertWhen_DoubleGuardianApproval() public {
        uint256 requestId = _setupLargeRequest();

        // Setup guardian1
        vm.startPrank(guardian1);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);
        vm.stopPrank();

        vm.prank(admin);
        pool.addGuardian(guardian1);

        // Vote and approve
        vm.prank(alice);
        pool.vote(requestId, true);
        vm.prank(bob);
        pool.vote(requestId, true);
        
        vm.warp(block.timestamp + 4 days);
        pool.finalizeVoting(requestId);

        // Guardian approves twice
        vm.startPrank(guardian1);
        pool.guardianApprove(requestId);
        
        vm.expectRevert(Pool.AlreadyApproved.selector);
        pool.guardianApprove(requestId);
        vm.stopPrank();
    }

    function test_RevertWhen_DoubleExecute() public {
        _setupPoolAndRequest();

        vm.prank(alice);
        pool.vote(0, true);
        vm.prank(bob);
        pool.vote(0, true);

        vm.warp(block.timestamp + 4 days);
        pool.finalizeVoting(0);
        pool.executeRequest(0);

        vm.expectRevert(Pool.InvalidStatus.selector);
        pool.executeRequest(0);
    }

    // ============ Timing Attack Tests ============

    function test_RevertWhen_VoteAfterPeriod() public {
        _setupPoolAndRequest();

        vm.warp(block.timestamp + 4 days);

        vm.prank(alice);
        vm.expectRevert(Pool.VotingEnded.selector);
        pool.vote(0, true);
    }

    function test_RevertWhen_FinalizeBeforePeriod() public {
        _setupPoolAndRequest();

        vm.expectRevert(Pool.VotingNotEnded.selector);
        pool.finalizeVoting(0);
    }

    function test_RevertWhen_ExecuteBeforeFinalize() public {
        _setupPoolAndRequest();

        vm.expectRevert(Pool.InvalidStatus.selector);
        pool.executeRequest(0);
    }

    // ============ Overflow/Underflow Tests ============

    function test_LargeDepositDoesNotOverflow() public {
        uint256 largeAmount = type(uint128).max;
        usdc.mint(alice, largeAmount);

        vm.startPrank(alice);
        usdc.approve(address(pool), largeAmount);
        pool.deposit(largeAmount);
        vm.stopPrank();

        assertEq(pool.totalDeposited(), largeAmount);
        assertEq(pool.shareToken().balanceOf(alice), largeAmount);
    }

    function test_RevertWhen_WithdrawMoreThanBalance() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);

        vm.expectRevert(); // ERC20 will revert on insufficient balance
        pool.withdraw(600 * 1e18);
        vm.stopPrank();
    }

    // ============ State Manipulation Tests ============

    function test_CannotManipulateSharePrice() public {
        // Alice deposits first
        vm.startPrank(alice);
        usdc.approve(address(pool), 100 * 1e18);
        pool.deposit(100 * 1e18);
        vm.stopPrank();

        // Attacker tries to manipulate by depositing then withdrawing
        vm.prank(admin);
        pool.addToWhitelist(attacker);

        vm.startPrank(attacker);
        usdc.approve(address(pool), 1000 * 1e18);
        pool.deposit(1000 * 1e18);
        pool.withdraw(1000 * 1e18);
        vm.stopPrank();

        // Bob deposits - should get 1:1 shares still
        vm.startPrank(bob);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);
        vm.stopPrank();

        assertEq(pool.shareToken().balanceOf(bob), 500 * 1e18);
    }

    // ============ Guardian Threshold Edge Cases ============

    function test_JustBelowGuardianThreshold() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000 * 1e18);
        pool.deposit(1000 * 1e18);
        vm.stopPrank();

        // Guardian threshold is 20% = 200 USDC, so 199 should NOT need guardian
        uint256 belowThreshold = 199 * 1e18;

        vm.startPrank(attacker);
        uint256 requestId = pool.createRequest(
            "Just below threshold",
            "ipfs://test",
            belowThreshold,
            Pool.RequestType.GRANT,
            0,
            30 days,
            address(0),
            0
        );
        vm.stopPrank();

        vm.prank(alice);
        pool.vote(requestId, true);

        vm.warp(block.timestamp + 4 days);
        pool.finalizeVoting(requestId);

        // Below threshold - should NOT need guardian
        pool.executeRequest(requestId);
        
        Pool.FundingRequest memory request = pool.getRequest(requestId);
        assertEq(uint256(request.status), uint256(Pool.RequestStatus.FUNDED));
    }

    function test_JustAboveGuardianThreshold() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000 * 1e18);
        pool.deposit(1000 * 1e18);
        vm.stopPrank();

        // Just above 20% threshold
        uint256 aboveThreshold = 201 * 1e18;

        vm.startPrank(attacker);
        uint256 requestId = pool.createRequest(
            "Just above threshold",
            "ipfs://test",
            aboveThreshold,
            Pool.RequestType.GRANT,
            0,
            30 days,
            address(0),
            0
        );
        vm.stopPrank();

        vm.prank(alice);
        pool.vote(requestId, true);

        vm.warp(block.timestamp + 4 days);
        pool.finalizeVoting(requestId);

        // Above threshold - NEEDS guardian
        vm.expectRevert(Pool.GuardianApprovalRequired.selector);
        pool.executeRequest(requestId);
    }

    // ============ Loan with Collateral Test ============

    function test_CreateLoanWithCollateral() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000 * 1e18);
        pool.deposit(1000 * 1e18);
        vm.stopPrank();

        uint256 collateralAmount = 100 * 1e18;
        collateralToken.mint(attacker, collateralAmount);

        vm.startPrank(attacker);
        collateralToken.approve(address(pool), collateralAmount);
        
        uint256 requestId = pool.createRequest(
            "Loan with collateral",
            "ipfs://test",
            200 * 1e18,
            Pool.RequestType.LOAN,
            1000,
            30 days,
            address(collateralToken),
            collateralAmount
        );
        vm.stopPrank();

        // Collateral should be in pool
        assertEq(collateralToken.balanceOf(address(pool)), collateralAmount);

        Pool.FundingRequest memory request = pool.getRequest(requestId);
        assertEq(request.collateralAmount, collateralAmount);
        assertEq(request.collateralToken, address(collateralToken));
    }

    function test_RevertWhen_LoanWithoutCollateral() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000 * 1e18);
        pool.deposit(1000 * 1e18);
        vm.stopPrank();

        // Request amount small enough to not trigger RequestTooLarge
        vm.startPrank(attacker);
        vm.expectRevert(Pool.CollateralRequired.selector);
        pool.createRequest(
            "Loan without collateral",
            "ipfs://test",
            100 * 1e18,  // Small enough
            Pool.RequestType.LOAN,
            1000,
            30 days,
            address(0),
            0
        );
        vm.stopPrank();
    }

    // ============ Helper Functions ============

    function _setupPoolAndRequest() internal returns (uint256) {
        vm.startPrank(alice);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(pool), 1000 * 1e18);
        pool.deposit(1000 * 1e18);
        vm.stopPrank();

        vm.startPrank(attacker);
        uint256 requestId = pool.createRequest(
            "Test Request",
            "ipfs://test",
            200 * 1e18,
            Pool.RequestType.GRANT,
            0,
            30 days,
            address(0),
            0
        );
        vm.stopPrank();

        return requestId;
    }

    function _setupLargeRequest() internal returns (uint256) {
        vm.startPrank(alice);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(pool), 1000 * 1e18);
        pool.deposit(1000 * 1e18);
        vm.stopPrank();

        // Large request > 20% of pool
        vm.startPrank(attacker);
        uint256 requestId = pool.createRequest(
            "Large Request",
            "ipfs://test",
            400 * 1e18,
            Pool.RequestType.GRANT,
            0,
            30 days,
            address(0),
            0
        );
        vm.stopPrank();

        return requestId;
    }
}
