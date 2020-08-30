const ganache = require('ganache-core');

module.exports = {
    contracts_directory: './contracts',
    contracts_build_directory: './contracts/build',
    networks: {
        development: {
            host: 'localhost',
            port: 7545,
            network_id: '*',
            gasPrice: 20000000000,
            gas: 9500000,
            provider: ganache.provider({
                gasLimit: 9500000,
                gasPrice: 20000000000,
                default_balance_ether: 10000000000000000000
            })
        },
        production: {
            host: 'localhost',
            port: 7545,
            network_id: '*',
            gasPrice: 20000000000,
            gas: 9500000
        }
    },
    compilers: {
        solc: {
            version: "0.6.2"
        }
    }
};
