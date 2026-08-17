# Popy site

Landing page and documentation for Popy, deployed to Cloudflare Pages.

## How the docs work

There is no separate documentation source. The build copies the repository
README into `src/` and renders it with `react-markdown`:

```
cp ../README.md ./src/README.md
cp ../assets/*.png public/assets/
```

`App.tsx` strips everything above the first `---` (the logo, badges, and nav
row, which the page renders as its own hero) and renders the remainder, then
builds the sidebar by parsing `##` and `###` headings.

The practical consequence: **edit `README.md` at the repo root, never here.**
The docs cannot drift from the README because they are the same file.

`src/README.md` and `public/assets/` are generated and gitignored.

## Local development

```bash
npm install
npm run dev      # copies the README, then starts Vite
npm run build    # type-checks and builds to dist/
```

## Deployment

`.github/workflows/site.yml` builds and deploys to Cloudflare Pages on every
push to `master` that touches `site/`, `README.md`, or `assets/`.

It requires two repository secrets:

| Secret | Where to get it |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | Cloudflare dashboard → My Profile → API Tokens → Create Token → *Edit Cloudflare Workers* template |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard → Workers & Pages → Account ID in the right sidebar |

The workflow creates the Pages project if it does not already exist, so the
first run needs no manual dashboard setup.

## Stack

Vite, React 19, TypeScript, Tailwind CSS 3, and a few shadcn/ui primitives.
Same template as [conops](https://github.com/anuragxxd/conops).
