import rss from "@astrojs/rss";
import type { APIContext } from "astro";
import { getSortedPosts } from "../lib/posts";

export async function GET(context: APIContext) {
	const posts = await getSortedPosts();

	return rss({
		title: "Preston Peranich",
		description:
			"Research engineer, open-source contributor. Writing about Rust, Nix, and embedded systems.",
		site: context.site ?? new URL("https://prestonperanich.com"),
		items: posts.map((post) => ({
			title: post.data.title,
			pubDate: post.data.pubDate,
			description: post.data.description,
			link: `/posts/${post.id}/`,
			categories: post.data.tags,
		})),
	});
}
