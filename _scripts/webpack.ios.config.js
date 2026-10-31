// Builds the renderer for the native iOS app in the `ios` directory.
// It is based on the web build, but bundles YouTube.js and googlevideo, so that the local API works.
// The native app provides the networking (no CORS restrictions), the poToken generation and the file handling.
const path = require('path')
const webpack = require('webpack')
const HtmlWebpackPlugin = require('html-webpack-plugin')
const { sigFrameTemplateParameters } = require('./sigFrameConfig')

// Read by src/index.ejs at build time
process.env.IS_IOS = 'true'

const config = require('./webpack.web.config.js')

config.name = 'ios'
config.entry = {
  web: path.join(__dirname, '../src/renderer/main.js'),
}
config.output.path = path.join(__dirname, '../dist/ios')
// The iOS app doesn't use a service worker
config.output.copy = config.output.copy.filter(entry => entry.from !== 'static/pwabuilder-sw.js')
config.output.copy.forEach(entry => {
  if (entry.from === 'static') {
    entry.globOptions.ignore.push('static/manifest.json', 'static/pwabuilder-*')
  }
})

delete config.externals

config.resolve.alias['youtubei.js$'] = 'youtubei.js/web'

config.plugins = config.plugins.map(plugin => {
  if (plugin instanceof webpack.DefinePlugin && 'process.env.SUPPORTS_LOCAL_API' in plugin.definitions) {
    return new webpack.DefinePlugin({
      ...plugin.definitions,
      'process.env.IS_IOS': true,
      'process.env.SUPPORTS_LOCAL_API': true,
    })
  }

  if (plugin instanceof HtmlWebpackPlugin) {
    return new HtmlWebpackPlugin({
      excludeChunks: ['processTaskWorker'],
      filename: 'index.html',
      template: path.resolve(__dirname, '../src/index.ejs'),
      templateParameters: sigFrameTemplateParameters
    })
  }

  return plugin
})

module.exports = config
