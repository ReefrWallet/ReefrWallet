import Foundation

// Chainlink proxy feeds per chain, keyed by token contract address (never by symbol, which spam tokens copy).
// Each entry is token, feed and the feed's heartbeat in seconds. The first entry is the chain's native token,
// priced through its wrapped token's feed.
extension ChainlinkPriceSource.FeedLookup {
    private struct Entry {
        let token: String
        let feed: String
        let heartbeat: TimeInterval

        init(_ token: String, _ feed: String, _ heartbeat: TimeInterval) {
            self.token = token
            self.feed = feed
            self.heartbeat = heartbeat
        }
    }

    private static func table(_ entries: [Entry]) -> Self {
        let feeds = entries.map { ChainlinkPriceSource.Feed(address: $0.feed, heartbeat: $0.heartbeat) }

        return .table(
            native: feeds[0],
            tokens: Dictionary(uniqueKeysWithValues: zip(entries.map(\.token), feeds))
        )
    }

    static let arbitrum = table([
        Entry("0x82af49447d8a07e3bd95bd0d56f35241523fbab1", "0x639fe6ab55c921f74e7fac1ee960c0b6293ba612", 1_755),
        Entry("0x2f2a2543b76a4166549f7aab2e75bef0aefc5b0f", "0x6ce185860a4963106506c203335a2910413708e9", 1_755),
        Entry("0x912ce59144191c1204e64559fe8253a0e49e6548", "0xb2a824043730fe05f3da2efafa1cbbe83fa548d6", 86_400),
        Entry("0xaf88d065e77c8cc2239327c5edb3a432268e5831", "0x50834f3163758fcc1df9973b6e91f0f0f0434ad3", 255),
        Entry("0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9", "0x3f3f5df88dc9f13eac63df89ec16ef6e7e25dde7", 255),
        Entry("0xda10009cbd5d07dd0cecc66161fc93d7c9000da1", "0xc5c8e77b397e531b8ec06bfb0048328b30e9ecfb", 86_400),
        Entry("0xf97f4df75117a78c1a5a0dbb814af92458539fb4", "0x86e53cf1b870786351da77a57575e79cb55812cb", 1_755)
    ])

    static let avalanche = table([
        Entry("0xb31f66aa3c1e785363f0875a1b74e27b85fd66c7", "0x0a77230d17318075983913bc2145db16c7366156", 120),
        Entry("0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e", "0xf096872672f44d6eba71458d74fe67f9a77a23b9", 86_400),
        Entry("0x9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7", "0xebe676ee90fe1112671f19b6b7459bc678b67e8a", 86_400),
        Entry("0xd586e7f844cea2f87f50152665bcbc2c279d8d70", "0x51d7180eda2260cc4f6e4eebb82fef5c3c2b8300", 86_400),
        Entry("0x50b7545627a5162f82a992c33b87adc75187b218", "0x86442e3a98558357d46e6182f4b262f76c4fa26f", 86_400),
        Entry("0x49d5c2bdffac6ce2bfdb6640f4f80f226bc10bab", "0x976b3d034e162d8bd72d6b9c989d545b839003b0", 86_400),
        Entry("0x5947bb275c521040051d82396192181b413227a3", "0x49ccd9ca821efeab2b98c60dc60f518e765ede9a", 86_400)
    ])

    static let base = table([
        Entry("0x4200000000000000000000000000000000000006", "0x71041dddad3595f9ced3dccfbe3d1f4b0a16bb70", 1_200),
        Entry("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", "0x7e860098f58bbfc8648a4311b374b1d669a2bc6b", 86_400),
        Entry("0xfde4c96c8593536e31f229ea8f37b2ada2699bb2", "0xf19d560eb8d2adf07bd6d13ed03e1d11215721f9", 86_400),
        Entry("0x50c5725949a6f0c72e6c4a641f24049a917db0cb", "0x591e79239a7d679378ec8c847e5038150364c78f", 86_400),
        Entry("0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf", "0x07da0e54543a844a80abe69c8a12f22b3aa59f9d", 1_200),
        Entry("0x88fb150bdc53a65fe94dea0c9ba0a6daf8c6e196", "0x17cab8fe31e32f08326e5e27412894e49b0f9d65", 86_400)
    ])

    static let bsc = table([
        Entry("0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c", "0x0567f2323251f0aab15c8dfb1967e4e8a7d42aee", 27),
        Entry("0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d", "0x51597f405303c4377e36123cbc172b13269ea163", 900),
        Entry("0x55d398326f99059ff775485246999027b3197955", "0xb97ad0e74fa7d920791e90258a6e2085088b4320", 900),
        Entry("0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3", "0x132d3c0b1d2cea0bc552588063bdbb210fdeecfa", 900),
        Entry("0x7130d2a12b9bcbfae4f2634d864a1ee1ce3ead9c", "0x264990fbd0a4796a3e3d8e37c4d5f87a3aca5ebf", 60),
        Entry("0x2170ed0880ac9a755fd29b2688956bd959f933f8", "0x9ef1b8c0e4f7dc8bf5719ea496883dc6401d5b2e", 60),
        Entry("0xf8a0bf9cf54bb92f17374d9e9a321e6a111a51bd", "0xca236e327f629f9fc2c30a4e95775ebf0b89fac8", 600)
    ])

    /// Feeds resolved from `<symbol>-usd.data.eth` and checked by `description()`; WBTC uses the BTC feed.
    /// Heartbeats are the 24 h ceiling of Chainlink's Ethereum crypto/USD feeds, since the exact ones weren't checked.
    static let ethereum = table([
        Entry("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419", 86_400),
        Entry("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "0x8fffffd4afb6115b954bd326cbe7b4ba576818f6", 86_400),
        Entry("0xdac17f958d2ee523a2206206994597c13d831ec7", "0x3e7d1eab13ad0104d2750b8863b489d65364e32d", 86_400),
        Entry("0x6b175474e89094c44da98b954eedeac495271d0f", "0xaed0c38402a5d19df6e4c03f4e2dced6e29c1ee9", 86_400),
        Entry("0x2260fac5e5542a773aa44fbcfedf7c193bc2c599", "0xf4030086522a5beea4988f8ca5b36dbc97bee88c", 86_400),
        Entry("0x514910771af9ca656af840dff83e8264ecf986ca", "0x2c1d072e956affc0d435cb7ac38ef18d24d9127c", 86_400),
        Entry("0x1f9840a85d5af5bf1d1762f925bdaddc4201f984", "0x553303d460ee0afb37edff9be42922d8ff63220e", 86_400),
        Entry("0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9", "0x547a514d5e3769680ce22b2361c10ea13619e8a9", 86_400),
        Entry("0x9f8f72aa9304c8b593d555f12ef6589cc3a579a2", "0xec1d1b3b0443256cc3860e24a46f108e699484aa", 86_400),
        Entry("0xd533a949740bb3306d119cc777fa900ba034cd52", "0xcd627aa160a6fa45eb793d19ef54f5062f20f33f", 86_400),
        Entry("0xc00e94cb662c3520282e6f5717214004a7f26888", "0xdbd020caef83efd542f4de03e3cf0c28a4428bd5", 86_400)
    ])

    static let hyperEVM = table([
        Entry("0x5555555555555555555555555555555555555555", "0xa5a72ef19f82a579431186402425593a559ed352", 86_400),
        Entry("0xb88339cb7199b77e23db6e890353e22632ba630f", "0xa0adc43ce7afe3ee7d7eac3c994e178d0620223b", 86_400),
        Entry("0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb", "0x9114446540b4f8e0e310041981f7c1be6181ed07", 86_400),
        Entry("0x9fdbda0a5e284c32744d2f17ee5c74b284993463", "0xd7752d8831a209f5177de52b3b32b5098a7b56b8", 86_400),
        Entry("0xbe6727b535545c67d5caa73dea54865b92cf7907", "0x54ede484bb0e589f5ee13e04c84f46eb787c9c6a", 86_400)
    ])

    static let mantle = table([
        Entry("0x78c1b0c915c4faa5fffa6cabf0219da63d7f4cb8", "0xd97f20bebed74e8144134c4b148fe93417dd0f96", 86_400),
        Entry("0x09bc4e0d864854c6afb6eb9a9cdf58ac190d0df9", "0x22b422cecb0d4bd5aff3ea999b048fa17f5263bd", 86_400),
        Entry("0x201eba5cc46d216ce6dc03f6a759e8e766e956ae", "0xd86048d5e4fe96157ce03ae519a9045bedaa6551", 86_400),
        Entry("0xdeaddeaddeaddeaddeaddeaddeaddeaddead1111", "0x5bc7cf88eb131db18b5d7930e793095140799ad5", 86_400),
        Entry("0xfe36cf0b43aae49fbc5cfc5c0af22a623114e043", "0x5871adbeedad531c68a8fd32fe86f07d6b4c645d", 86_400)
    ])

    static let monad = table([
        Entry("0x3bd359c1119da7da1d913d1c4d2b7c461115433a", "0xbcd78f76005b7515837af6b50c7c52bcf73822fb", 3_600),
        Entry("0x754704bc059f8c67012fed69bc8a327a5aafb603", "0xf5f15f188abcb0d165d1edb7f37f7d6fa2fcebec", 3_600),
        Entry("0xe7cd86e13ac4309349f30b3435a9d337750fc82d", "0x1a1be4c184923a6bff8c27cfdf6ac8bde4de00fc", 3_600),
        Entry("0xee8c0e9f1bffb4eb878d8f15f368a02a35481242", "0x1b1414782b859871781ba3e4b0979b9ca57a0a04", 3_600),
        Entry("0x0555e30da8f98308edb960aa94c0db47230d2b9c", "0xc1d4c3331635184fa4c3c22fb92211b2ac9e0546", 3_600),
        Entry("0xd18b7ec58cdf4876f6afebd3ed1730e4ce10414b", "0x3ddc1bae752aaee31b577bf844c799c349a1d6bd", 3_600),
        Entry("0x76f257b1dda5cc71bee4ef637fbdde4c801310a9", "0x5c266b5c655664d6c99a13ff0d7f1f7eaf4ac9ba", 3_600)
    ])

    static let optimism = table([
        Entry("0x4200000000000000000000000000000000000006", "0x13e3ee699d1909e989722e753853ae30b17e08c5", 1_200),
        Entry("0x0b2c639c533813f4aa9d7837caf62653d097ff85", "0x16a9fa2fda030272ce99b29cf780dfa30361e0f3", 86_400),
        Entry("0x94b008aa00579c1307b0ef2c499ad98a8ce58e58", "0xecef79e109e997bca29c1c0897ec9d7b03647f5e", 86_400),
        Entry("0xda10009cbd5d07dd0cecc66161fc93d7c9000da1", "0x8dba75e83da73cc766a7e5a0ee71f656bab470d6", 86_400),
        Entry("0x68f180fcce6836688e9084f035309e29bf0a2095", "0xd702dd976fb76fffc2d3963d037dfdae5b04e593", 1_200),
        Entry("0x4200000000000000000000000000000000000042", "0x0d276fc14719f9292d5c1ea2198673d1f4269246", 1_200),
        Entry("0x350a791bfc2c21f9ed5d10980dad2e2638ffa7f6", "0xcc232dcfaae6354ce191bd574108c1ad03f86450", 1_200)
    ])

    static let polygon = table([
        Entry("0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270", "0xab594600376ec9fd91f8e885dadf0ce036862de0", 27),
        Entry("0x3c499c542cef5e3811e1192ce70d8cc03d5c3359", "0xfe4a8cc5b5b2366c1b58bea3858e81843581b2f7", 27),
        Entry("0xc2132d05d31c914a87c6611c10748aeb04b58e8f", "0x0a6513e40db6eb1b165753ad52e80663aea50545", 27),
        Entry("0x8f3cf7ad23cd3cadbd9735aff958023239c6a063", "0x4746dec9e833a82ec7c2c1356372ccf2cfcd2f3d", 27),
        Entry("0x7ceb23fd6bc0add59e62ac25578270cff1b9f619", "0xf9680d99d6c9589e2a93a78a04a279e509205945", 27),
        Entry("0x1bfd67037b42cf73acf2047067bd4f2c47d9bfd6", "0xc907e116054ad103354f2d350fd2514433d57f6f", 27),
        Entry("0x53e0bca35ec356bd5dddfebbd1fc0fd03fabad39", "0xd9ffdb71ebe7496cc440152d43986aae0ab76665", 27)
    ])

    static let robinhood = table([
        Entry("0x0bd7d308f8e1639fab988df18a8011f41eacad73", "0x5058adee53b04e374d8bedbad634bc4778f50b22", 86_400),
        Entry("0x5fc5360d0400a0fd4f2af552add042d716f1d168", "0x901f56689360b89d7767a8ace28b7801e6348fa2", 86_400),
        Entry("0x5d3a1ff2b6bab83b63cd9ad0787074081a52ef34", "0xd9b1f2958298f25bf1289b5aab7fb6d1b7416c95", 3_600),
        Entry("0xcec185eb182c47d1ba1efc84e6959e18cd620be4", "0x3546407c5f94dd7eab3a853d245b5c5eab53318a", 86_400),
        Entry("0x492641f648a4986844848e0befe66d14817bce34", "0xb7f054718bd802716fa7bd5944df2f50a8d0424e", 86_400)
    ])

    static let unichain = table([
        Entry("0x4200000000000000000000000000000000000006", "0x41cfbba7be6e03fc43a19689b31852af205da864", 86_400),
        Entry("0x078d782b760474a361dda0af3839290b0ef57ad6", "0xbd1cd1518efb92a92100da62d4c488c810dfd75b", 86_400),
        Entry("0x8f187aa05619a017077f5308904739877ce9ea21", "0xe061653d202ef5881c55f021c4d136a090989e87", 86_400),
        Entry("0x0555e30da8f98308edb960aa94c0db47230d2b9c", "0x2751e96985a43b83fa289a465464caf9a3431664", 86_400),
        Entry("0xef66491eab4bbb582c57b14778afd8dfb70d8a1a", "0x04343180aba8543a850a87d594644d84fe38a919", 86_400)
    ])
}
