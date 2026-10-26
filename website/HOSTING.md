# Website hosting

The site is hosted on Cloudflare Pages in the `tennisbuddy` project.

- Custom domain: https://tennisbuddy.net
- Cloudflare URL: https://tennisbuddy.pages.dev
- Dashboard: https://dash.cloudflare.com/f4d685670c2bba7116a40663ea1d80f8/pages/view/tennisbuddy

To publish updates, run `npm run deploy:website` from the repository root.
The build copies `website/index.html` and `website/img/` into `.website-dist/`.
Alternate design pages and this document are excluded from publication.

Wrangler uses the existing Cloudflare login. If it expires, run `npx wrangler login`.
