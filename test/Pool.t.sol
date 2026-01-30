// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Pool.sol";
import "../src/PoolFactory.sol";
import "../src/ShareToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1_000_000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PoolTest is Test {
    PoolFactory factory;
    Pool pool;
    MockERC20 usdc;
    MockERC20 collateralToken;

    address admin = address(1);
    address alice = address(2);
    address bob = address(3);
    address carol = address(4);
    address guardian1 = address(5);
    address guardian2 = address(6);
    address projectRequester = address(7);

    function setUp() public {
        // Deploy tokens
        usdc = new MockERC20();
        collateralToken = new MockERC20();

        // Deploy factory
        factory = new PoolFactory();

        // Create pool as admin
        vm.startPrank(admin);
        
        address[] memory guardians = new address[](2);
        guardians[0] = guardian1;
        guardians[1] = guardian2;

        address poolAddr = factory.createPool(
            "Alpha Circle",
            address(usdc),
            100 * 1e18,      // 100 USDC min deposit
            3 days,          // voting period
            5000,            // 50% quorum
            6000,            // 60% approval threshold
            2000,            // 20% guardian threshold
            guardians
        );

        pool = Pool(payable(poolAddr));

        // Whitelist members
        pool.addToWhitelist(alice);
        pool.addToWhitelist(bob);
        pool.addToWhitelist(carol);
        pool.addToWhitelist(guardian1);
        pool.addToWhitelist(guardian2);

        vm.stopPrank();

        // Give everyone USDC
        usdc.mint(admin, 1000 * 1e18);
        usdc.mint(alice, 1000 * 1e18);
        usdc.mint(bob, 2000 * 1e18);
        usdc.mint(carol, 1000 * 1e18);
        usdc.mint(guardian1, 500 * 1e18);
        usdc.mint(guardian2, 500 * 1e18);
        usdc.mint(projectRequester, 100 * 1e18);
        collateralToken.mint(projectRequester, 1000 * 1e18);
    }

    // ============ Deposit Tests ============

    function test_Deposit() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);
        vm.stopPrank();

        assertEq(pool.totalDeposited(), 500 * 1e18);
        assertEq(pool.shareToken().balanceOf(alice), 500 * 1e18);
        (bool isActive,,) = pool.members(alice);
        assertTrue(isActive);
    }

    function test_MultipleDeposits() public {
        // Alice deposits 500
        vm.startPrank(alice);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);
        vm.stopPrank();

        // Bob deposits 1000
        vm.startPrank(bob);
        usdc.approve(address(pool), 1000 * 1e18);
        pool.deposit(1000 * 1e18);
        vm.stopPrank();

        assertEq(pool.totalDeposited(), 1500 * 1e18);
        
        // Check proportional shares
        uint256 aliceShares = pool.shareToken().balanceOf(alice);
        uint256 bobShares = pool.shareToken().balanceOf(bob);
        
        // Alice: 500/1500 = 33.33%
        // Bob: 1000/1500 = 66.66%
        assertEq(aliceShares, 500 * 1e18);
        assertEq(bobShares, 1000 * 1e18);
    }

    function test_RevertWhen_DepositBelowMin() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 50 * 1e18);
        vm.expectRevert(Pool.BelowMinDeposit.selector);
        pool.deposit(50 * 1e18);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositNotWhitelisted() public {
        address random = address(99);
        usdc.mint(random, 500 * 1e18);
        
        vm.startPrank(random);
        usdc.approve(address(pool), 500 * 1e18);
        vm.expectRevert(Pool.NotWhitelisted.selector);
        pool.deposit(500 * 1e18);
        vm.stopPrank();
    }

    // ============ Withdrawal Tests ============

    function test_Withdraw() public {
        // Alice deposits
        vm.startPrank(alice);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);

        uint256 balanceBefore = usdc.balanceOf(alice);
        
        // Alice withdraws half her shares
        pool.withdraw(250 * 1e18);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), balanceBefore + 250 * 1e18);
        assertEq(pool.shareToken().balanceOf(alice), 250 * 1e18);
        assertEq(pool.totalDeposited(), 250 * 1e18);
    }

    // ============ Funding Request Tests ============

    function test_CreateGrantRequest() public {
        _setupPoolWithFunds();

        vm.startPrank(projectRequester);
        uint256 requestId = pool.createRequest(
            "Build Cool App",
            "ipfs://description",
            200 * 1e18,
            Pool.RequestType.GRANT,
            0,              // no reward expected
            30 days,
            address(0),     // no collateral for grants
            0
        );
        vm.stopPrank();

        Pool.FundingRequest memory request = pool.getRequest(requestId);
        assertEq(request.amount, 200 * 1e18);
        assertEq(uint256(request.requestType), uint256(Pool.RequestType.GRANT));
        assertEq(uint256(request.status), uint256(Pool.RequestStatus.VOTING));
    }

    function test_CreateLoanRequestWithCollateral() public {
        _setupPoolWithFunds();

        vm.startPrank(projectRequester);
        collateralToken.approve(address(pool), 100 * 1e18);
        
        uint256 requestId = pool.createRequest(
            "Need Working Capital",
            "ipfs://description",
            200 * 1e18,
            Pool.RequestType.LOAN,
            1000,           // 10% interest
            60 days,
            address(collateralToken),
            100 * 1e18      // collateral required
        );
        vm.stopPrank();

        Pool.FundingRequest memory request = pool.getRequest(requestId);
        assertEq(request.collateralAmount, 100 * 1e18);
        assertEq(collateralToken.balanceOf(address(pool)), 100 * 1e18);
    }

    function test_RevertWhen_LoanWithoutCollateral() public {
        _setupPoolWithFunds();

        vm.startPrank(projectRequester);
        vm.expectRevert(Pool.CollateralRequired.selector);
        pool.createRequest(
            "Need Loan",
            "ipfs://description",
            200 * 1e18,
            Pool.RequestType.LOAN,
            1000,
            60 days,
            address(0),
            0
        );
        vm.stopPrank();
    }

    // ============ Voting Tests ============

    function test_VoteAndApprove() public {
        _setupPoolWithFunds();
        uint256 requestId = _createGrantRequest();

        // Alice votes yes (500 shares)
        vm.prank(alice);
        pool.vote(requestId, true);

        // Bob votes yes (1000 shares)
        vm.prank(bob);
        pool.vote(requestId, true);

        Pool.FundingRequest memory request = pool.getRequest(requestId);
        assertEq(request.yesVotes, 1500 * 1e18);

        // Fast forward past voting period
        vm.warp(block.timestamp + 4 days);

        // Finalize
        pool.finalizeVoting(requestId);

        request = pool.getRequest(requestId);
        assertEq(uint256(request.status), uint256(Pool.RequestStatus.APPROVED));
    }

    function test_VoteAndReject() public {
        _setupPoolWithFunds();
        uint256 requestId = _createGrantRequest();

        // Alice votes no (500 shares)
        vm.prank(alice);
        pool.vote(requestId, false);

        // Bob votes no (1000 shares)
        vm.prank(bob);
        pool.vote(requestId, false);

        // Fast forward
        vm.warp(block.timestamp + 4 days);

        // Finalize
        pool.finalizeVoting(requestId);

        Pool.FundingRequest memory request = pool.getRequest(requestId);
        assertEq(uint256(request.status), uint256(Pool.RequestStatus.REJECTED));
    }

    function test_QuorumNotMet() public {
        _setupPoolWithFunds();
        uint256 requestId = _createGrantRequest();

        // Only Alice votes (500 of 1500 = 33%, below 50% quorum)
        vm.prank(alice);
        pool.vote(requestId, true);

        vm.warp(block.timestamp + 4 days);
        pool.finalizeVoting(requestId);

        Pool.FundingRequest memory request = pool.getRequest(requestId);
        assertEq(uint256(request.status), uint256(Pool.RequestStatus.REJECTED));
    }

    // ============ Execution Tests ============

    function test_ExecuteSmallRequest() public {
        _setupPoolWithFunds();
        uint256 requestId = _createGrantRequest(); // 200 USDC < 20% of 1500

        // Vote and approve
        vm.prank(alice);
        pool.vote(requestId, true);
        vm.prank(bob);
        pool.vote(requestId, true);

        vm.warp(block.timestamp + 4 days);
        pool.finalizeVoting(requestId);

        // Execute - no guardian needed
        uint256 balanceBefore = usdc.balanceOf(projectRequester);
        pool.executeRequest(requestId);

        assertEq(usdc.balanceOf(projectRequester), balanceBefore + 200 * 1e18);
        
        Pool.FundingRequest memory request = pool.getRequest(requestId);
        assertEq(uint256(request.status), uint256(Pool.RequestStatus.FUNDED));
    }

    function test_ExecuteLargeRequestNeedsGuardians() public {
        _setupPoolWithFunds();

        // Create large request (400 USDC > 20% of 1500)
        vm.startPrank(projectRequester);
        uint256 requestId = pool.createRequest(
            "Big Project",
            "ipfs://description",
            400 * 1e18,
            Pool.RequestType.GRANT,
            0,
            30 days,
            address(0),
            0
        );
        vm.stopPrank();

        // Vote and approve
        vm.prank(alice);
        pool.vote(requestId, true);
        vm.prank(bob);
        pool.vote(requestId, true);

        vm.warp(block.timestamp + 4 days);
        pool.finalizeVoting(requestId);

        // Try to execute - should fail without guardian approval
        vm.expectRevert(Pool.GuardianApprovalRequired.selector);
        pool.executeRequest(requestId);

        // Guardians need to deposit first to be active members
        vm.startPrank(guardian1);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);
        vm.stopPrank();

        vm.startPrank(guardian2);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);
        vm.stopPrank();

        // Add as guardians
        vm.startPrank(admin);
        pool.addGuardian(guardian1);
        pool.addGuardian(guardian2);
        vm.stopPrank();

        // Guardian approves
        vm.prank(guardian1);
        pool.guardianApprove(requestId);

        vm.prank(guardian2);
        pool.guardianApprove(requestId);

        // Now execute works
        uint256 balanceBefore = usdc.balanceOf(projectRequester);
        pool.executeRequest(requestId);
        assertEq(usdc.balanceOf(projectRequester), balanceBefore + 400 * 1e18);
    }

    // ============ Share Token Tests ============

    function test_ShareTokenNonTransferable() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);
        
        ShareToken token = pool.shareToken();
        
        vm.expectRevert(ShareToken.TransfersDisabled.selector);
        token.transfer(bob, 100 * 1e18);
        vm.stopPrank();
    }

    // ============ Helper Functions ============

    function _setupPoolWithFunds() internal {
        vm.startPrank(alice);
        usdc.approve(address(pool), 500 * 1e18);
        pool.deposit(500 * 1e18);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(pool), 1000 * 1e18);
        pool.deposit(1000 * 1e18);
        vm.stopPrank();
    }

    function _createGrantRequest() internal returns (uint256) {
        vm.startPrank(projectRequester);
        uint256 requestId = pool.createRequest(
            "Build Cool App",
            "ipfs://description",
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
}
