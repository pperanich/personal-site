import type { APIRoute } from "astro";
import { getCollection } from "astro:content";

export const GET: APIRoute = async () => {
	const posts = (await getCollection("blog")).sort(
		(a, b) => b.data.pubDate.valueOf() - a.data.pubDate.valueOf(),
	);

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
