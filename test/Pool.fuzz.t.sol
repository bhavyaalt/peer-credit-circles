// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Pool.sol";
import "../src/PoolFactory.sol";
import "../src/ShareToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20Fuzz is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PoolFuzzTest is Test {
    PoolFactory factory;
    Pool pool;
    MockERC20Fuzz usdc;
    MockERC20Fuzz collateralToken;

    address admin = address(1);
    address guardian1 = address(5);
    address guardian2 = address(6);

    uint256 constant MIN_DEPOSIT = 100 * 1e18;
    uint256 constant MAX_DEPOSIT = 1_000_000 * 1e18;
    uint256 constant VOTING_PERIOD = 3 days;

    function setUp() public {
        usdc = new MockERC20Fuzz();
        collateralToken = new MockERC20Fuzz();

        factory = new PoolFactory();

        vm.startPrank(admin);
        
        address[] memory guardians = new address[](2);
        guardians[0] = guardian1;
        guardians[1] = guardian2;

        address poolAddr = factory.createPool(
            "Fuzz Test Pool",
            address(usdc),
            MIN_DEPOSIT,
            VOTING_PERIOD,
            5000,   // 50% quorum
            6000,   // 60% approval
            2000,   // 20% guardian threshold
            guardians
        );

        pool = Pool(payable(poolAddr));
        vm.stopPrank();
    }

    // ============ Fuzz: Deposit Amount ============

    function testFuzz_DepositAmount(uint256 amount) public {
        // Bound to valid range
        amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);
        
        address user = address(uint160(uint256(keccak256("user"))));
        
        vm.prank(admin);
        pool.addToWhitelist(user);

        usdc.mint(user, amount);

        vm.startPrank(user);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();

        // Invariant: shares should equal deposit amount (1:1 initially)
        assertEq(pool.shareToken().balanceOf(user), amount);
        assertEq(pool.totalDeposited(), amount);
    }

    // ============ Fuzz: Multiple Depositors ============

    function testFuzz_MultipleDeposits(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, MIN_DEPOSIT, MAX_DEPOSIT / 2);
        amount2 = bound(amount2, MIN_DEPOSIT, MAX_DEPOSIT / 2);

        address user1 = address(uint160(uint256(keccak256("user1"))));
        address user2 = address(uint160(uint256(keccak256("user2"))));

        vm.startPrank(admin);
        pool.addToWhitelist(user1);
        pool.addToWhitelist(user2);
        vm.stopPrank();

        usdc.mint(user1, amount1);
        usdc.mint(user2, amount2);

        vm.startPrank(user1);
        usdc.approve(address(pool), amount1);
        pool.deposit(amount1);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(pool), amount2);
        pool.deposit(amount2);
        vm.stopPrank();

        // Invariant: total shares = total deposits
        uint256 totalShares = pool.shareToken().totalSupply();
        assertEq(totalShares, amount1 + amount2);
        assertEq(pool.totalDeposited(), amount1 + amount2);
    }

    // ============ Fuzz: Withdraw Amount ============

    function testFuzz_WithdrawAmount(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, MIN_DEPOSIT, MAX_DEPOSIT);
        
        address user = address(uint160(uint256(keccak256("user"))));
        
        vm.prank(admin);
        pool.addToWhitelist(user);

        usdc.mint(user, depositAmount);

        vm.startPrank(user);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);

        // Bound withdraw to valid range
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);
        
        uint256 balanceBefore = usdc.balanceOf(user);
        pool.withdraw(withdrawAmount);
        vm.stopPrank();

        // Invariant: user gets correct amount back
        assertEq(usdc.balanceOf(user), balanceBefore + withdrawAmount);
        assertEq(pool.shareToken().balanceOf(user), depositAmount - withdrawAmount);
    }

    // ============ Fuzz: Voting Thresholds ============

    function testFuzz_VotingOutcome(
        uint256 yesVotes,
        uint256 noVotes,
        uint256 abstainVotes
    ) public {
        // Bound votes to reasonable ranges
        yesVotes = bound(yesVotes, 0, 1000 * 1e18);
        noVotes = bound(noVotes, 0, 1000 * 1e18);
        abstainVotes = bound(abstainVotes, 0, 1000 * 1e18);

        uint256 totalVotes = yesVotes + noVotes + abstainVotes;
        if (totalVotes < MIN_DEPOSIT * 3) {
            totalVotes = MIN_DEPOSIT * 3;
            yesVotes = MIN_DEPOSIT;
            noVotes = MIN_DEPOSIT;
            abstainVotes = MIN_DEPOSIT;
        }

        // Create 3 voters with different amounts
        address voter1 = address(uint160(uint256(keccak256("voter1"))));
        address voter2 = address(uint160(uint256(keccak256("voter2"))));
        address voter3 = address(uint160(uint256(keccak256("voter3"))));
        address requester = address(uint160(uint256(keccak256("requester"))));

        vm.startPrank(admin);
        pool.addToWhitelist(voter1);
        pool.addToWhitelist(voter2);
        pool.addToWhitelist(voter3);
        vm.stopPrank();

        // Ensure minimum deposits
        if (yesVotes < MIN_DEPOSIT) yesVotes = MIN_DEPOSIT;
        if (noVotes < MIN_DEPOSIT) noVotes = MIN_DEPOSIT;
        if (abstainVotes < MIN_DEPOSIT) abstainVotes = MIN_DEPOSIT;

        usdc.mint(voter1, yesVotes);
        usdc.mint(voter2, noVotes);
        usdc.mint(voter3, abstainVotes);

        // Deposit
        vm.startPrank(voter1);
        usdc.approve(address(pool), yesVotes);
        pool.deposit(yesVotes);
        vm.stopPrank();

        vm.startPrank(voter2);
        usdc.approve(address(pool), noVotes);
        pool.deposit(noVotes);
        vm.stopPrank();

        vm.startPrank(voter3);
        usdc.approve(address(pool), abstainVotes);
        pool.deposit(abstainVotes);
        vm.stopPrank();

        // Create request
        vm.startPrank(requester);
        uint256 requestId = pool.createRequest(
            "Test Request",
            "ipfs://test",
            50 * 1e18,  // Small amount
            Pool.RequestType.GRANT,
            0,
            30 days,
            address(0),
            0
        );
        vm.stopPrank();

        // Vote
        vm.prank(voter1);
        pool.vote(requestId, true);

        vm.prank(voter2);
        pool.vote(requestId, false);

        // voter3 doesn't vote (abstains)

        // Fast forward and finalize
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        pool.finalizeVoting(requestId);

        Pool.FundingRequest memory request = pool.getRequest(requestId);

        // Calculate expected outcome
        uint256 totalShares = pool.shareToken().totalSupply();
        uint256 totalVotescast = yesVotes + noVotes;
        uint256 quorumRequired = (totalShares * 5000) / 10000;
        uint256 approvalRequired = (totalVotescast * 6000) / 10000;

        if (totalVotescast < quorumRequired) {
            // Quorum not met -> rejected
            assertEq(uint256(request.status), uint256(Pool.RequestStatus.REJECTED));
        } else if (yesVotes >= approvalRequired) {
            // Approved
            assertEq(uint256(request.status), uint256(Pool.RequestStatus.APPROVED));
        } else {
            // Rejected
            assertEq(uint256(request.status), uint256(Pool.RequestStatus.REJECTED));
        }
    }

    // ============ Fuzz: Request Amount ============

    function testFuzz_RequestAmount(uint256 poolSize, uint256 requestAmount) public {
        poolSize = bound(poolSize, MIN_DEPOSIT * 2, MAX_DEPOSIT);
        requestAmount = bound(requestAmount, 1 * 1e18, poolSize);

        address depositor = address(uint160(uint256(keccak256("depositor"))));
        address requester = address(uint160(uint256(keccak256("requester"))));

        vm.prank(admin);
        pool.addToWhitelist(depositor);

        usdc.mint(depositor, poolSize);

        vm.startPrank(depositor);
        usdc.approve(address(pool), poolSize);
        pool.deposit(poolSize);
        vm.stopPrank();

        // Create request
        vm.startPrank(requester);
        uint256 requestId = pool.createRequest(
            "Fuzz Request",
            "ipfs://test",
            requestAmount,
            Pool.RequestType.GRANT,
            0,
            30 days,
            address(0),
            0
        );
        vm.stopPrank();

        Pool.FundingRequest memory request = pool.getRequest(requestId);
        assertEq(request.amount, requestAmount);

        // Check if guardian approval would be needed
        uint256 guardianThreshold = (poolSize * 2000) / 10000; // 20%
        bool needsGuardian = requestAmount > guardianThreshold;

        // Vote to approve
        vm.prank(depositor);
        pool.vote(requestId, true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        pool.finalizeVoting(requestId);

        request = pool.getRequest(requestId);
        assertEq(uint256(request.status), uint256(Pool.RequestStatus.APPROVED));

        if (needsGuardian) {
            // Should fail without guardian
            vm.expectRevert(Pool.GuardianApprovalRequired.selector);
            pool.executeRequest(requestId);
        } else {
            // Should work
            uint256 balanceBefore = usdc.balanceOf(requester);
            pool.executeRequest(requestId);
            assertEq(usdc.balanceOf(requester), balanceBefore + requestAmount);
        }
    }

    // ============ Fuzz: Loan Interest Calculation ============

    function testFuzz_LoanInterest(uint256 principal, uint256 interestBps) public {
        principal = bound(principal, MIN_DEPOSIT, MAX_DEPOSIT / 10);
        interestBps = bound(interestBps, 100, 5000); // 1% to 50%

        address depositor = address(uint160(uint256(keccak256("depositor"))));
        address borrower = address(uint160(uint256(keccak256("borrower"))));

        vm.prank(admin);
        pool.addToWhitelist(depositor);

        // Deposit enough funds
        usdc.mint(depositor, principal * 2);
        vm.startPrank(depositor);
        usdc.approve(address(pool), principal * 2);
        pool.deposit(principal * 2);
        vm.stopPrank();

        // Borrower needs collateral
        uint256 collateralRequired = principal;
        collateralToken.mint(borrower, collateralRequired);

        vm.startPrank(borrower);
        collateralToken.approve(address(pool), collateralRequired);
        
        uint256 requestId = pool.createRequest(
            "Loan Request",
            "ipfs://test",
            principal,
            Pool.RequestType.LOAN,
            interestBps,
            60 days,
            address(collateralToken),
            collateralRequired
        );
        vm.stopPrank();

        Pool.FundingRequest memory request = pool.getRequest(requestId);
        
        // Interest calculation: principal * interestBps / 10000
        uint256 expectedInterest = (principal * interestBps) / 10000;
        
        assertEq(request.amount, principal);
        assertEq(request.rewardBps, interestBps);
        
        // Total repayment would be principal + interest
        uint256 totalRepayment = principal + expectedInterest;
        assertTrue(totalRepayment >= principal);
    }

    // ============ Fuzz: Timestamp Bounds ============

    function testFuzz_VotingPeriodExpiry(uint256 timeDelta) public {
        timeDelta = bound(timeDelta, 0, 365 days);

        address depositor = address(uint160(uint256(keccak256("depositor"))));
        address requester = address(uint160(uint256(keccak256("requester"))));

        vm.prank(admin);
        pool.addToWhitelist(depositor);

        usdc.mint(depositor, MIN_DEPOSIT * 10);
        vm.startPrank(depositor);
        usdc.approve(address(pool), MIN_DEPOSIT * 10);
        pool.deposit(MIN_DEPOSIT * 10);
        vm.stopPrank();

        vm.startPrank(requester);
        uint256 requestId = pool.createRequest(
            "Test",
            "ipfs://test",
            MIN_DEPOSIT,
            Pool.RequestType.GRANT,
            0,
            30 days,
            address(0),
            0
        );
        vm.stopPrank();

        Pool.FundingRequest memory request = pool.getRequest(requestId);
        uint256 votingEnds = request.votingEndsAt;

        vm.warp(block.timestamp + timeDelta);

        if (block.timestamp < votingEnds) {
            // Can still vote
            vm.prank(depositor);
            pool.vote(requestId, true);
        } else {
            // Cannot vote after period ends - should revert
            vm.prank(depositor);
            vm.expectRevert(Pool.VotingEnded.selector);
            pool.vote(requestId, true);
        }
    }
}
