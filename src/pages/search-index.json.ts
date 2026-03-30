import type { APIRoute } from "astro";
import { getSortedPosts } from "../lib/posts";

export const GET: APIRoute = async () => {
	const posts = await getSortedPosts();

	const index = posts.map((post) => ({
		id: post.id,
		title: post.data.title,
		description: post.data.description,
		tags: post.data.tags,
		pubDate: post.data.pubDate.toISOString(),
	}));

	return new Response(JSON.stringify(index), {
		headers: { "Content-Type": "application/json" },
	});
};
