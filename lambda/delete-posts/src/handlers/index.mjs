import GhostAdminAPI from '@tryghost/admin-api';

export const handler = async () => {
    const api = new GhostAdminAPI({
        url: process.env.GHOST_URL,
        key: process.env.KEY,
        version: process.env.VERSION
    });

    let response = null;
    let options = {
        page: 0,
        limit: 500,
        fields: ["id"]
    };
    do {
        response = await api.posts.browse(options);
        console.log('Posts to Delete:', JSON.stringify(response, null, 2));
        await Promise.all(response.map(post=>api.posts.delete({id: post.id})));
    } while (response.length);
}
