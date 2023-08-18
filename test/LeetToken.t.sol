// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";

import {DeployLeetToken, LeetToken} from "../script/DeployLeetToken.s.sol";
import "@leetswap/interfaces/IUniswapV2Router02.sol";
import "@leetswap/interfaces/IUniswapV2Factory.sol";
import "@leetswap/interfaces/IUniswapV2Pair.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";

contract TestLeetToken is Test {
    uint256 mainnetFork;

    DeployLeetToken public leetDeployer;
    LeetToken public leet;

    IUniswapV2Factory public factory;
    IUniswapV2Router02 public router;

    WETH public weth;
    MockERC20 public pairToken;

    function setUp() public {
        mainnetFork = vm.createSelectFork("https://mainnet.base.org", 2606723);

        router = IUniswapV2Router02(0xd3Ea3BC1F5A3F881bD6cE9761cbA5A0833a5d737);
        factory = IUniswapV2Factory(router.factory());
        weth = WETH(payable(router.WETH()));

        pairToken = new MockERC20("PairToken", "PT", 18);

        leetDeployer = new DeployLeetToken();
        leet = leetDeployer.run(address(router), address(weth));

        vm.label(address(leetDeployer), "leetDeployer");
        vm.label(address(factory), "factory");
        vm.label(address(router), "router");
        vm.label(address(leet), "leet");
        vm.label(address(weth), "weth");
        vm.label(address(pairToken), "pairToken");

        vm.startPrank(leet.owner());
        leet.setMaxWalletEnabled(false);
        vm.stopPrank();

        vm.deal(address(this), 100 ether);
        weth.deposit{value: 10 ether}();

        assertEq(leet.balanceOf(leet.owner()), 1337000 * 1e18);
    }

    function addLiquidityWithETH(
        uint256 tokenAmount,
        uint256 ethAmount
    ) public {
        address liquidityManager = leet.owner();

        vm.startPrank(liquidityManager);

        leet.approve(address(router), tokenAmount);
        router.addLiquidityETH{value: ethAmount}(
            address(leet),
            tokenAmount,
            0,
            0,
            liquidityManager,
            block.timestamp
        );

        address pair = factory.getPair(address(leet), address(weth));
        leet.addLeetPair(pair);

        vm.stopPrank();
    }

    function addLiquidityWithPairToken(
        uint256 tokenAmount,
        uint256 pairTokenAmount
    ) public {
        address liquidityManager = leet.owner();

        pairToken.mint(liquidityManager, pairTokenAmount);

        vm.startPrank(liquidityManager);

        leet.approve(address(router), tokenAmount);
        pairToken.approve(address(router), pairTokenAmount);
        router.addLiquidity(
            address(leet),
            address(pairToken),
            tokenAmount,
            pairTokenAmount,
            0,
            0,
            liquidityManager,
            block.timestamp
        );

        address pair = factory.getPair(address(leet), address(pairToken));
        leet.addLeetPair(pair);

        vm.stopPrank();
    }

    function testAddLiquidityWithETH() public {
        addLiquidityWithETH(800e3 ether, 10 ether);

        address pair = factory.getPair(address(leet), address(weth));
        assertEq(leet.balanceOf(pair), 800e3 ether);
        assertEq(weth.balanceOf(address(pair)), 10 ether);
    }

    function testAddLiquidityWithPairToken() public {
        addLiquidityWithPairToken(800e3 ether, 10 ether);

        address pair = factory.getPair(address(leet), address(pairToken));

        vm.prank(leet.owner());
        leet.addLeetPair(pair);

        assertEq(leet.balanceOf(pair), 800e3 ether);
        assertEq(pairToken.balanceOf(pair), 10 ether);
    }

    function testBuyTax() public {
        vm.prank(leet.owner());
        leet.enableTrading();
        vm.warp(block.timestamp);

        testAddLiquidityWithETH();
        vm.deal(address(this), 1 ether);

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(leet);

        address pair = factory.getPair(address(leet), address(weth));
        uint256 amountOut = router.getAmountOut(
            1 ether,
            IERC20Metadata(path[0]).balanceOf(pair),
            IERC20Metadata(path[1]).balanceOf(pair)
        );
        uint256 tax = (amountOut * leet.totalBuyFee()) / leet.FEE_DENOMINATOR();
        uint256 amountOutAfterTax = amountOut - tax;

        router.swapExactETHForTokens{value: 1 ether}(
            0,
            path,
            address(this),
            block.timestamp
        );

        assertEq(leet.balanceOf(address(this)), amountOutAfterTax);
    }

    function testIndirectSwapTaxEnabled() public {
        vm.startPrank(leet.owner());
        leet.enableTrading();
        leet.setIndirectSwapFeeEnabled(true);
        vm.stopPrank();
        vm.warp(block.timestamp);

        addLiquidityWithETH(400e3 ether, 5 ether);
        addLiquidityWithPairToken(400e3 ether, 5 ether);
        vm.deal(address(this), 1 ether);

        address[] memory path = new address[](3);
        path[0] = address(weth);
        path[1] = address(leet);
        path[2] = address(pairToken);

        address firstPair = factory.getPair(path[0], path[1]);
        uint256 leetAmountOut = router.getAmountOut(
            1 ether,
            IERC20Metadata(path[0]).balanceOf(firstPair),
            IERC20Metadata(path[1]).balanceOf(firstPair)
        );
        uint256 tax = (leetAmountOut * leet.totalSellFee()) /
            leet.FEE_DENOMINATOR();
        uint256 leetAmountOutAfterTax = leetAmountOut - tax;
        address secondPair = factory.getPair(path[1], path[2]);
        uint256 pairTokenAmountOut = router.getAmountOut(
            leetAmountOutAfterTax,
            IERC20Metadata(path[1]).balanceOf(secondPair),
            IERC20Metadata(path[2]).balanceOf(secondPair)
        );

        assertEq(pairToken.balanceOf(address(this)), 0);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: 1 ether
        }(0, path, address(this), block.timestamp);

        assertEq(pairToken.balanceOf(address(this)), pairTokenAmountOut);
    }

    function testIndirectSwapTaxDisabled() public {
        vm.prank(leet.owner());
        leet.enableTrading();
        vm.warp(block.timestamp);

        addLiquidityWithETH(400e3 ether, 5 ether);
        addLiquidityWithPairToken(400e3 ether, 5 ether);
        vm.deal(address(this), 1 ether);

        address[] memory path = new address[](3);
        path[0] = address(weth);
        path[1] = address(leet);
        path[2] = address(pairToken);

        uint256 pairTokenAmountOut = router.getAmountsOut(1 ether, path)[2];
        assertEq(pairToken.balanceOf(address(this)), 0);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: 1 ether
        }(0, path, address(this), block.timestamp);

        assertEq(pairToken.balanceOf(address(this)), pairTokenAmountOut);
    }

    function testSellTax() public {
        vm.prank(leet.owner());
        leet.enableTrading();
        vm.warp(block.timestamp);

        testAddLiquidityWithETH();
        vm.deal(address(this), 0 ether);

        vm.prank(leet.owner());
        leet.transfer(address(this), 1 ether);
        leet.approve(address(router), UINT256_MAX);

        address[] memory path = new address[](2);
        path[0] = address(leet);
        path[1] = address(weth);

        uint256 amountInAfterTax = 1 ether -
            (1 ether * leet.totalSellFee()) /
            leet.FEE_DENOMINATOR();
        address pair = factory.getPair(path[0], path[1]);
        IUniswapV2Pair(pair).sync();
        uint256 amountOut = router.getAmountOut(
            amountInAfterTax,
            IERC20Metadata(path[0]).balanceOf(pair),
            IERC20Metadata(path[1]).balanceOf(pair)
        );

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1 ether,
            0,
            path,
            address(this),
            block.timestamp
        );

        assertEq(address(this).balance, amountOut);
    }

    function testSwappingFeesOnTransfer() public {
        vm.prank(leet.owner());
        leet.setBuyFees(0, 0, 0, 10);

        testBuyTax();
        vm.warp(block.timestamp);

        uint256 taxTokens = leet.balanceOf(address(leet));
        uint256 maxSwapFeesAmount = leet.maxSwapFeesAmount();
        uint256 amountToSwap = taxTokens > maxSwapFeesAmount
            ? maxSwapFeesAmount
            : taxTokens;
        address pair = factory.getPair(address(leet), address(weth));
        uint256 amountOut = router.getAmountOut(
            amountToSwap,
            IERC20Metadata(address(leet)).balanceOf(pair),
            IERC20Metadata(address(weth)).balanceOf(pair)
        );

        vm.prank(address(1337));
        leet.transfer(address(42), 0);
        assertTrue(weth.balanceOf(leet.treasuryFeeRecipient()) > 0);
        assertEq(weth.balanceOf(leet.treasuryFeeRecipient()), amountOut);
    }

    function testSwappingFeesOnSells() public {
        vm.prank(leet.owner());
        leet.setBuyFees(0, 0, 0, 10);

        testBuyTax();
        vm.warp(block.timestamp);

        uint256 taxTokens = leet.balanceOf(address(leet));
        uint256 maxSwapFeesAmount = leet.maxSwapFeesAmount();
        uint256 amountToSwap = taxTokens > maxSwapFeesAmount
            ? maxSwapFeesAmount
            : taxTokens;
        address pair = factory.getPair(address(leet), address(weth));
        uint256 amountOut = router.getAmountOut(
            amountToSwap,
            IERC20Metadata(address(leet)).balanceOf(pair),
            IERC20Metadata(address(weth)).balanceOf(pair)
        );

        uint256 swapAmount = leet.balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = address(leet);
        path[1] = address(weth);

        leet.approve(address(router), swapAmount);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            swapAmount,
            0,
            path,
            address(this),
            block.timestamp
        );

        assertTrue(weth.balanceOf(leet.treasuryFeeRecipient()) > 0);
        assertEq(weth.balanceOf(leet.treasuryFeeRecipient()), amountOut);
    }

    function testMaxSwapFeesAmount() public {
        vm.prank(leet.owner());
        leet.enableTrading();

        testAddLiquidityWithETH();

        vm.prank(leet.owner());
        leet.transfer(address(leet), 1e3 ether);

        uint256 taxTokens = leet.balanceOf(address(leet));
        uint256 maxSwapFeesAmount = leet.maxSwapFeesAmount();
        uint256 amountToSwap = taxTokens > maxSwapFeesAmount
            ? maxSwapFeesAmount
            : taxTokens;
        address pair = factory.getPair(address(leet), address(weth));
        uint256 amountOut = router.getAmountOut(
            amountToSwap,
            IERC20Metadata(address(leet)).balanceOf(pair),
            IERC20Metadata(address(weth)).balanceOf(pair)
        );

        vm.prank(address(1337));
        leet.transfer(address(42), 0);
        assertTrue(weth.balanceOf(leet.treasuryFeeRecipient()) > 0);
        assertEq(weth.balanceOf(leet.treasuryFeeRecipient()), amountOut);
    }

    function testSetTradingEnabledTimestamp() public {
        testAddLiquidityWithPairToken();

        uint256 tradingEnabledTimestamp = block.timestamp + 1 days;
        vm.prank(leet.owner());
        leet.setTradingEnabledTimestamp(tradingEnabledTimestamp);

        address[] memory path = new address[](2);
        path[0] = address(pairToken);
        path[1] = address(leet);

        uint256 amountIn = 1 ether;
        pairToken.mint(address(this), amountIn);
        pairToken.approve(address(router), amountIn);

        vm.expectRevert("UniswapV2: TRANSFER_FAILED");
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            0,
            path,
            address(this),
            block.timestamp
        );

        vm.prank(leet.owner());
        leet.enableTrading();

        vm.expectRevert("UniswapV2: TRANSFER_FAILED");
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            0,
            path,
            address(this),
            block.timestamp
        );

        vm.warp(tradingEnabledTimestamp);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function testAddLiquidityWithPairTokenNotOwner() public {
        testBuyTax();
        // vm.deal(address(this), 1 ether);

        pairToken.mint(address(this), 1 ether);

        leet.approve(address(router), type(uint256).max);
        pairToken.approve(address(router), type(uint256).max);
        router.addLiquidity(
            address(leet),
            address(pairToken),
            leet.balanceOf(address(this)),
            1 ether,
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    function testDeployAndLaunch() public {
        uint256 pairTokenLiquidityAmount = 5000 ether;
        pairToken.mint(address(this), pairTokenLiquidityAmount);

        pairToken.mint(leet.owner(), pairTokenLiquidityAmount);

        LeetToken _leet = leetDeployer.deployAndLaunch(
            router,
            IERC20Metadata(address(pairToken)),
            pairTokenLiquidityAmount,
            block.timestamp + 1
        );
        leet = _leet;

        address pair = factory.getPair(address(leet), address(pairToken));
        assertEq(pairToken.balanceOf(pair), pairTokenLiquidityAmount);

        vm.warp(leet.tradingEnabledTimestamp() + 1);

        pairToken.mint(address(this), 1 ether);
        vm.deal(address(this), 1 ether);

        address[] memory path = new address[](2);
        path[0] = address(pairToken);
        path[1] = address(leet);

        uint256 amountOut = router.getAmountOut(
            1 ether,
            IERC20Metadata(address(pairToken)).balanceOf(pair),
            IERC20Metadata(address(leet)).balanceOf(pair)
        );

        uint256 buyTax = (amountOut * leet.totalBuyFee()) /
            leet.FEE_DENOMINATOR();
        uint256 amountOutAfterTax = amountOut - buyTax;

        pairToken.approve(address(router), UINT256_MAX);
        router.swapExactTokensForTokens(
            1 ether,
            0,
            path,
            address(this),
            block.timestamp
        );

        assertEq(leet.balanceOf(address(this)), amountOutAfterTax);

        pairToken.mint(address(this), 1 ether);

        leet.approve(address(router), type(uint256).max);
        pairToken.approve(address(router), type(uint256).max);
        router.addLiquidity(
            address(leet),
            address(pairToken),
            leet.balanceOf(address(this)),
            1 ether,
            0,
            0,
            address(this),
            block.timestamp + 60
        );
    }

    receive() external payable {}
}
