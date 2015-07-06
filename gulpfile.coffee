gulp = require 'gulp'
gutil = require 'gulp-util'
plumber = require 'gulp-plumber'
webpack = require 'webpack'
{join, dirname, basename, extname, relative, resolve} = require 'path'
{readFileSync, writeFileSync, existsSync, mkdirSync} = require 'fs'
{cloneDeep} = require 'lodash'
packager = require 'electron-packager'
GitHub = require 'github'
{spawn} = require 'child_process'
Q = require 'q'
{argv} = require 'yargs'
semver = require 'semver'
Git = require 'nodegit'


pkg = JSON.parse readFileSync 'package.json'
url = pkg.repository.url
owner = basename dirname url
repo = basename pkg.repository.url, extname url


gulp.task 'default', [
  'ready'
  'copy'
  'webpack'
]

gulp.task 'ready', ->
  if !existsSync 'dist'
    mkdirSync 'dist'
  p = cloneDeep pkg
  p.dependencies = chokidar: pkg.dependencies.chokidar
  delete p.devDependencies
  writeFileSync 'dist/package.json', JSON.stringify p

gulp.task 'copy', ->
  gulp
    .src ['./node_modules/chokidar/**/*'], base: '.'
    .pipe gulp.dest 'dist'

gulp.task 'webpack', ->
  w = ({entry, output}, cb) ->
    webpack
      entry: entry
      output:
        filename: output
      module:
        loaders: [
          test: /\.coffee$/
          loader: 'coffee-loader'
        ,
          test: /\.(css)$/,
          loader: 'css-loader'
        ,
          test: /\.woff2?(\?v=[0-9]\.[0-9]\.[0-9])?$/,
          loader: "url-loader?minetype=application/font-woff"
        ,
          test: /\.(ttf|eot|svg)(\?v=[0-9]\.[0-9]\.[0-9])?$/,
          loader: "file-loader"
        ]
      resolve:
        extensions: [
          ''
          '.js'
          '.coffee'
        ]
      externals: [
        do ->
          IGNORE = [
            # Node
            'fs'
            # Electron
            'crash-reporter'
            'app'
            'menu'
            'menu-item'
            'browser-window'
            'dialog'
            # Module
            'chokidar'
          ]
          (context, request, callback) ->
            return callback null, "require('#{request}')" if request in IGNORE
            callback()
      ]
      stats:
        colors: true
    , (err, stats) ->
      throw new gutil.PluginError 'webpack', err if err?
      gutil.log '[webpack]', stats.toString()
      cb?()
  w
    entry: './src/renderer/index.coffee'
    output: './tmp/renderer.js'
  , (err) ->
    w
      entry: './src/main/main.coffee'
      output: './dist/main.js'

gulp.task 'publish', ->
  releases = ['major', 'minor', 'patch']
  release = argv.r
  unless release in releases
    release = 'patch'
  version = semver.inc pkg.version, release

  pkg.version = version
  writeFileSync 'package.json', JSON.stringify pkg, null,  2

  Git.Repository
    .open resolve './.git'
    .then (repo) ->
      repo
        .getTree 'master'
        .then (tree) ->
          signature = Git.Signature.default repo
          Git.Commit repo, null, signature, signature, null, "Bump version to v#{version}", tree, 0, null
          return
    .catch (err) ->
      console.error err
  return

  Q
    .when ''
    .then ->
      d = Q.defer()
      packager
        dir: 'dist'
        name: pkg.name
        platform: 'all'
        arch: 'all'
        version: '0.29.1'
        overwrite: true
      ,  (err, dirs) ->
        throw new gutil.PluginError 'package', err if err?
        d.resolve dirs
      d.promise

    .then (dirs) ->
      dirs = dirs.map (dir) ->
        name = basename dir
        zip = "#{name}.zip"
        {dir, name, zip}

      github = new GitHub
        version: "3.0.0"
        debug: true
      github.authenticate
        type: 'oauth'
        token: process.env.TOKEN

      Q
        .all dirs.map ({name, zip}) ->
          d = Q.defer()
          console.log "zip #{name} to #{zip}"
          zip = spawn 'zip', [zip, '-r', name]
          zip.stdout.on 'data', (data) -> console.log data.toString 'utf8'
          zip.stderr.on 'data', (data) -> console.log data.toString 'utf8'
          zip.on 'close', (code) -> d.resolve()
          d.promise

        # .then ->
        #   d = Q.defer()
        #   console.log 'list releases'
        #   github.releases.listReleases
        #     owner: owner
        #     repo: repo
        #   , (err, res) ->
        #     throw err if err
        #     console.log JSON.stringify res, null, 2
        #     d.resolve res[0].id
        #   d.promise
        #
        # .then (id) ->
        #   d = Q.defer()
        #   console.log "delete release: #{id}"
        #   github.releases.deleteRelease
        #     owner: owner
        #     repo: repo
        #     id: id
        #   , (err, res) ->
        #     throw err if err
        #     console.log JSON.stringify res, null, 2
        #     d.resolve()
        #   d.promise

        .then ->
          d = Q.defer()
          console.log 'create new release'
          github.releases.createRelease
            owner: owner
            repo: repo
            tag_name: 'v0.0.3'
          , (err, res) ->
            throw err if err
            console.log JSON.stringify res, null, 2
            d.resolve res.id
          d.promise

        .then (id) ->
          console.log "complete to create new release: #{id}"

          Q
            .all dirs.map ({zip}) ->
              d = Q.defer()
              github.releases.uploadAsset
                owner: owner
                repo: repo
                id: id
                name: zip
                filePath: zip
              , (err, res) ->
                throw err if err?
                console.log JSON.stringify res, null, 2
                d.resolve()
              d.promise
            .then ->
              console.log 'complete to upload'
