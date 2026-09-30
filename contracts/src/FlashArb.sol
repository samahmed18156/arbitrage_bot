// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FlashArb
/// @notice Flash-loan funded 2-pool arbitrage between Uniswap-V2-style pairs.
///         Borrows `amount` of `token` from Balancer V2 (0% fee at time of writing),
///         swaps token -> quote on `pairBuy`, quote -> token on `pairSell`,
///         repays the loan and sends the profit to the owner.
///         The whole transaction reverts if profit < `minProfit`, so the worst case
///         is wasted gas - never a lost principal (you never had any at risk).
/// @dev    Educational code. Audit before putting real money behind it.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IBalancerVault {
    function flashLoan(address recipient, IERC20[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract FlashArb {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/
    address public immutable vault;
    address public owner;

    /// hash of the params of the in-flight arb. Non-zero only during executeArb.
    bytes32 private _expected;

    struct Route {
        address token;      // token borrowed & profit token (e.g. WETH)
        uint256 amount;     // flash loan size
        address pairBuy;    // pair where we swap token -> quote
        address pairSell;   // pair where we swap quote -> token
        uint16 feeBuyBps;   // swap fee of pairBuy  (30 = 0.30%)
        uint16 feeSellBps;  // swap fee of pairSell
        uint256 minProfit;  // revert unless profit >= this (in `token` units)
    }

    error NotOwner();
    error NotVault();
    error UnexpectedCallback();
    error InsufficientProfit(uint256 got, uint256 needed);
    error TransferFailed();
    error BadPair();

    event Arb(address indexed token, uint256 amount, uint256 profit);
    event OwnerChanged(address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _vault) {
        vault = _vault;
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                               ENTRYPOINT
    //////////////////////////////////////////////////////////////*/
    function executeArb(Route calldata r) external onlyOwner {
        bytes memory data = abi.encode(r);
        _expected = keccak256(data);

        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = IERC20(r.token);
        amounts[0] = r.amount;
        IBalancerVault(vault).flashLoan(address(this), tokens, amounts, data);

        _expected = bytes32(0);
    }

    /// @notice Balancer flash loan callback.
    function receiveFlashLoan(IERC20[] memory, uint256[] memory amounts, uint256[] memory fees, bytes memory data)
        external
    {
        if (msg.sender != vault) revert NotVault();
        // Stops anyone else from making the vault call us with attacker-chosen routes.
        if (_expected == bytes32(0) || keccak256(data) != _expected) revert UnexpectedCallback();

        Route memory r = abi.decode(data, (Route));

        // 1) token -> quote on pairBuy, 2) quote -> token on pairSell
        (address quote, uint256 quoteOut) = _swap(r.pairBuy, r.token, r.amount, r.feeBuyBps);
        (, uint256 tokenOut) = _swap(r.pairSell, quote, quoteOut, r.feeSellBps);

        uint256 owed = amounts[0] + fees[0];
        if (tokenOut < owed + r.minProfit) {
            revert InsufficientProfit(tokenOut > owed ? tokenOut - owed : 0, r.minProfit);
        }

        _safeTransfer(r.token, vault, owed);
        uint256 profit = IERC20(r.token).balanceOf(address(this));
        _safeTransfer(r.token, owner, profit);
        emit Arb(r.token, r.amount, profit);
    }

    /*//////////////////////////////////////////////////////////////
                                 SWAP
    //////////////////////////////////////////////////////////////*/
    function _swap(address pair, address tokenIn, uint256 amountIn, uint256 feeBps)
        internal
        returns (address tokenOut, uint256 amountOut)
    {
        IUniswapV2Pair p = IUniswapV2Pair(pair);
        (uint256 r0, uint256 r1,) = p.getReserves();
        address t0 = p.token0();

        bool zeroIn = tokenIn == t0;
        (uint256 reserveIn, uint256 reserveOut) = zeroIn ? (r0, r1) : (r1, r0);
        if (reserveIn == 0 || reserveOut == 0) revert BadPair();

        uint256 inWithFee = amountIn * (10_000 - feeBps);
        amountOut = (inWithFee * reserveOut) / (reserveIn * 10_000 + inWithFee);

        _safeTransfer(tokenIn, pair, amountIn);
        if (zeroIn) p.swap(0, amountOut, address(this), "");
        else p.swap(amountOut, 0, address(this), "");

        // pair's "other" token
        tokenOut = zeroIn ? _token1(pair) : t0;
    }

    function _token1(address pair) private view returns (address t) {
        (bool ok, bytes memory ret) = pair.staticcall(abi.encodeWithSignature("token1()"));
        if (!ok || ret.length < 32) revert BadPair();
        t = abi.decode(ret, (address));
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/
    function setOwner(address n) external onlyOwner {
        require(n != address(0), "zero");
        owner = n;
        emit OwnerChanged(n);
    }

    /// @notice Sweep any stray tokens (shouldn't normally hold any).
    function rescue(address token) external onlyOwner {
        _safeTransfer(token, owner, IERC20(token).balanceOf(address(this)));
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
