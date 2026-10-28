#!/usr/bin/env node
// Usage: NETWORKS="..." TOKENS="..." node build.mjs [resources-dir]
// Builds Networks.xcassets (16pt magenta template icons) and Tokens.xcassets
// (16pt color circles) from @web3icons/core SVGs. Run via ../make_web3icons.sh.
//
// NETWORKS entries: "<network-id>[=<name>]"           -> "<name>Network16"
// TOKENS entries:   "<SYMBOL>[=network:<network-id>[:fit]]" -> "<symbol>Token16"
// A `network:` source takes the network's background icon when the token has none.
// `:fit` shrinks it onto a white circle so a full-bleed square logo fits entirely inside.

import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

// Template icons are magenta to make untinted use visible early.
const TEMPLATE_COLOR = '#FF00FF'
const SIZE = 16

const resourcesDir = process.argv[2] ?? '../../Resources'

const camelCase = (string) =>
  string
    .replace(/[-_ ]+(.)/g, (_, char) => char.toUpperCase())
    .replace(/^./, (char) => char.toLowerCase())

const entries = (list) =>
  (list ?? '')
    .split(/\s+/)
    .filter(Boolean)
    .map((entry) => entry.split('='))

const loadSVG = async (kind, variant, id) => {
  try {
    return (await import(`@web3icons/core/svgs/${kind}/${variant}/${id}.svg.js`)).default
  } catch {
    throw new Error(`No ${variant} icon for ${kind.slice(0, -1)} "${id}"`)
  }
}

const resize = (svg) =>
  svg
    .replace(/ class="web3icons"/, '')
    .replace(/(<svg[^>]*?) width="\d+"/, `$1 width="${SIZE}"`)
    .replace(/(<svg[^>]*?) height="\d+"/, `$1 height="${SIZE}"`)

const tinted = (svg) =>
  svg.replace(/\b(fill|stroke)="(?!none")[^"]*"/g, `$1="${TEMPLATE_COLOR}"`)

// Assumes the source viewBox is 0 0 24 24.
const circular = (svg, id) =>
  resize(svg)
    .replace(
      /(<svg[^>]*>)/,
      `$1\n<defs><clipPath id="${id}__circle"><circle cx="12" cy="12" r="12"/></clipPath></defs>\n<g clip-path="url(#${id}__circle)">`
    )
    .replace(/<\/svg>\s*$/, '</g>\n</svg>\n')

const FIT_SCALE = 0.66

// Square logo scaled to sit entirely inside the circle, on a white disc.
const fitted = (svg) =>
  svg
    .replace(
      /(<svg[^>]*>)/,
      `$1\n<circle cx="12" cy="12" r="12" fill="#fff"/>\n<g transform="translate(12 12) scale(${FIT_SCALE}) translate(-12 -12)">`
    )
    .replace(/<\/svg>\s*$/, '</g>\n</svg>\n')

const contentsJSON = (properties) => ({
  info: { author: 'xcode', version: 1 },
  ...(properties && { properties }),
})

const makeCatalog = (name) => {
  const dir = join(resourcesDir, `${name}.xcassets`)
  rmSync(dir, { force: true, recursive: true })
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'Contents.json'), JSON.stringify(contentsJSON(), null, 2) + '\n')
  return dir
}

const writeImageSet = (catalogDir, name, svg, isTemplate) => {
  const dir = join(catalogDir, `${name}.imageset`)
  mkdirSync(dir)
  writeFileSync(join(dir, `${name}.svg`), svg)
  const contents = {
    images: [{ filename: `${name}.svg`, idiom: 'universal' }],
    ...contentsJSON({
      'preserves-vector-representation': true,
      ...(isTemplate && { 'template-rendering-intent': 'template' }),
    }),
  }
  writeFileSync(join(dir, 'Contents.json'), JSON.stringify(contents, null, 2) + '\n')
}

const networksDir = makeCatalog('Networks')
for (const [id, name = id] of entries(process.env.NETWORKS)) {
  const assetName = `${camelCase(name)}Network${SIZE}`
  writeImageSet(networksDir, assetName, tinted(resize(await loadSVG('networks', 'mono', id))), true)
  console.log(`Networks: ${assetName}`)
}

const tokensDir = makeCatalog('Tokens')
for (const [symbol, source] of entries(process.env.TOKENS)) {
  const assetName = `${camelCase(symbol.toLowerCase())}Token${SIZE}`
  const [, networkId, fit] = source?.match(/^network:([^:]+)(:fit)?$/) ?? []
  if (source && !networkId) {
    throw new Error(`Bad token source "${source}"`)
  }

  const svg = networkId
    ? await loadSVG('networks', 'background', networkId)
    : await loadSVG('tokens', 'background', symbol)
  writeImageSet(tokensDir, assetName, circular(fit ? fitted(svg) : svg, assetName), false)
  console.log(`Tokens: ${assetName}`)
}
