// SPDX-License-Identifier:AGPL-3.0-only
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {LeetToken} from "@leetswap/tokens/LeetToken.sol";
import {IUniswapV2Router02} from "@leetswap/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "@leetswap/interfaces/IUniswapV2Factory.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract DeployLeetToken is Test {
    using Strings for uint256;

    uint256 public constant TOTAL_SUPPLY = 1337000 ether;
    uint256 public constant TEAM_SHARE = 500;
    uint256 public constant MARKETING_SHARE = 500;
    uint256 public constant LIQUIDITY_SHARE = 1000;
    uint256 public constant REWARDS_SHARE = 8000;
    uint256 public constant TOTAL_SHARE =
        TEAM_SHARE + MARKETING_SHARE + LIQUIDITY_SHARE + REWARDS_SHARE;

    uint64 public constant TEAM_CLIFF = 180 days;
    uint64 public constant TEAM_VESTING = 2 * 365 days;
    uint64 public constant MARKETING_VESTING = 2 * 365 days;

    uint256 public constant TEAM_SUPPLY =
        (TOTAL_SUPPLY * TEAM_SHARE) / TOTAL_SHARE;
    uint256 public constant MARKETING_SUPPLY =
        (TOTAL_SUPPLY * MARKETING_SHARE) / TOTAL_SHARE;
    uint256 public constant LIQUIDITY_SUPPLY =
        (TOTAL_SUPPLY * LIQUIDITY_SHARE) / TOTAL_SHARE;
    uint256 public constant REWARDS_SUPPLY =
        TOTAL_SUPPLY - TEAM_SUPPLY - MARKETING_SUPPLY - LIQUIDITY_SUPPLY;

    function setUp() public {
        console.log(
            "Running script on chain with ID:",
            block.chainid.toString()
        );
        assertEq(TOTAL_SHARE, 1e4);
    }

    function run(
        address router,
        address swapPairToken
    ) external returns (LeetToken leet) {
        leet = deploy(router, swapPairToken);
    }

    function deploy(
        address router,
        address swapPairToken
    ) public returns (LeetToken leet) {
        require(swapPairToken != address(0), "Swap pair token cannot be zero");

        vm.broadcast();
        return new LeetToken(router, swapPairToken);
    }

    function deployAndLaunch(
        IUniswapV2Router02 router,
        IERC20Metadata pairToken,
        uint256 pairTokenLiquidityAmount,
        uint256 launchTimestamp
    ) external returns (LeetToken leet) {
        assertGt(launchTimestamp, block.timestamp);

        console.log("Trading will be enabled at:", launchTimestamp);
        console.log("PAIRTOKEN:", address(pairToken));
        console.log(
            "Initial liquidity PAIRTOKEN:",
            pairTokenLiquidityAmount / 10 ** pairToken.decimals()
        );

        leet = deploy(address(router), address(pairToken));

        vm.startBroadcast();
        address sender = leet.owner();
        assertGe(pairToken.balanceOf(sender), pairTokenLiquidityAmount);
        console.log("Leet token deployed at:", address(leet));

        leet.setTradingEnabledTimestamp(launchTimestamp);
        assertEq(TOTAL_SUPPLY, leet.totalSupply());
        assertEq(leet.balanceOf(sender), TOTAL_SUPPLY);

        assertEq(
            TEAM_SUPPLY + MARKETING_SUPPLY + LIQUIDITY_SUPPLY + REWARDS_SUPPLY,
            TOTAL_SUPPLY
        );

        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        IERC20Metadata lpToken = IERC20Metadata(
            factory.getPair(address(leet), address(pairToken))
        );
        assertEq(lpToken.totalSupply(), 0);

        VestingWallet teamWallet = new VestingWallet(
            sender, // beneficiary
            uint64(launchTimestamp + TEAM_CLIFF), // start
            TEAM_VESTING // duration
        );
        leet.excludeFromMaxWallet(address(teamWallet));
        leet.transfer(address(teamWallet), TEAM_SUPPLY);

        VestingWallet marketingWallet = new VestingWallet(
            sender, // beneficiary
            uint64(launchTimestamp), // start
            MARKETING_VESTING // duration
        );
        leet.excludeFromMaxWallet(address(marketingWallet));
        leet.transfer(address(marketingWallet), MARKETING_SUPPLY);

        leet.approve(address(router), type(uint256).max);
        pairToken.approve(address(router), type(uint256).max);
        uint256 initialLiquidityAmount = LIQUIDITY_SUPPLY;
        (, , uint256 liquidity) = router.addLiquidity(
            address(leet),
            address(pairToken),
            initialLiquidityAmount,
            pairTokenLiquidityAmount,
            0,
            0,
            sender,
            block.timestamp + 10 minutes
        );

        uint256 lpTokenBalance = lpToken.balanceOf(sender);
        assertEq(liquidity, lpTokenBalance);

        assertEq(
            leet.balanceOf(sender),
            TOTAL_SUPPLY - LIQUIDITY_SUPPLY - TEAM_SUPPLY - MARKETING_SUPPLY
        );
        assertEq(leet.balanceOf(address(leet)), 0);

        leet.enableTrading();

        vm.stopBroadcast();
    }
}
