
/*
 * Copyright (C) bigplum@gmail.com
 */


#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

#if (NGX_EXPR)
#include <ngx_http_expr_module.h>
#endif


typedef struct {
    u_char                         color;
    u_short                        len;
    u_short                        conn;
    u_char                         data[1];
} ngx_http_limit_traffic_rate_node_t;


typedef struct {
    ngx_shm_zone_t                *shm_zone;
    ngx_rbtree_node_t             *node;
    size_t                         limit;
} ngx_http_limit_traffic_rate_cleanup_t;


typedef struct {
    ngx_rbtree_t                  *rbtree;
    ngx_http_complex_value_t       key;
} ngx_http_limit_traffic_rate_ctx_t;


typedef struct {
    ngx_shm_zone_t                *shm_zone;

#if (NGX_EXPR)
    ngx_array_t                   *rates;
#else
    size_t                         rate;
#endif

} ngx_http_limit_traffic_rate_limit_t;


typedef struct {
    ngx_array_t                    limits;
} ngx_http_limit_traffic_rate_conf_t;


typedef struct {
    ngx_http_request_t            *request;
    ngx_array_t                    limits;
    unsigned                       skip:1;
} ngx_http_limit_traffic_rate_req_ctx_t;


static ngx_int_t ngx_http_limit_traffic_rate_header_filter(
    ngx_http_request_t *r);
static ngx_int_t ngx_http_limit_traffic_rate_body_filter(ngx_http_request_t *r,
    ngx_chain_t *in);
static void ngx_http_limit_traffic_rate_update(ngx_http_request_t *r,
    ngx_http_limit_traffic_rate_req_ctx_t *ctx);
static void ngx_http_limit_traffic_rate_cleanup(void *data);
static void ngx_http_limit_traffic_rate_rbtree_insert_value(
    ngx_rbtree_node_t *temp, ngx_rbtree_node_t *node,
    ngx_rbtree_node_t *sentinel);
static ngx_int_t ngx_http_limit_traffic_rate_init_zone(ngx_shm_zone_t *shm_zone,
    void *data);
static void *ngx_http_limit_traffic_rate_create_conf(ngx_conf_t *cf);
static char *ngx_http_limit_traffic_rate_merge_conf(ngx_conf_t *cf,
    void *parent, void *child);
static char *ngx_http_limit_traffic_rate_zone(ngx_conf_t *cf,
    ngx_command_t *cmd, void *conf);
static char *ngx_http_limit_traffic_rate(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf);
static ngx_int_t ngx_http_limit_traffic_rate_init(ngx_conf_t *cf);


static ngx_command_t  ngx_http_limit_traffic_rate_commands[] = {

    { ngx_string("limit_traffic_rate_zone"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE2,
      ngx_http_limit_traffic_rate_zone,
      0,
      0,
      NULL },

    { ngx_string("limit_traffic_rate"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF

#if (NGX_EXPR)
                       |NGX_HTTP_MAIN_WHEN_CONF|NGX_HTTP_SRV_WHEN_CONF
                       |NGX_HTTP_LOC_WHEN_CONF
#endif

                       |NGX_CONF_TAKE2,
      ngx_http_limit_traffic_rate,
      NGX_HTTP_LOC_CONF_OFFSET,
      0,
      NULL },

      ngx_null_command
};


static ngx_http_module_t  ngx_http_limit_traffic_rate_filter_module_ctx = {
    NULL,                                    /* preconfiguration */
    ngx_http_limit_traffic_rate_init,        /* postconfiguration */

    NULL,                                    /* create main configuration */
    NULL,                                    /* init main configuration */

    NULL,                                    /* create server configuration */
    NULL,                                    /* merge server configuration */

    ngx_http_limit_traffic_rate_create_conf, /* create location configuration */
    ngx_http_limit_traffic_rate_merge_conf   /* merge location configuration */
};


ngx_module_t  ngx_http_limit_traffic_rate_filter_module = {
    NGX_MODULE_V1,
    &ngx_http_limit_traffic_rate_filter_module_ctx, /* module context */
    ngx_http_limit_traffic_rate_commands,           /* module directives */
    NGX_HTTP_MODULE,                                /* module type */
    NULL,                                           /* init master */
    NULL,                                           /* init module */
    NULL,                                           /* init process */
    NULL,                                           /* init thread */
    NULL,                                           /* exit thread */
    NULL,                                           /* exit process */
    NULL,                                           /* exit master */
    NGX_MODULE_V1_PADDING
};


static ngx_http_output_header_filter_pt  ngx_http_next_header_filter;
static ngx_http_output_body_filter_pt    ngx_http_next_body_filter;


/* A zero rate disables nginx's limiter. Never round a share down to zero. */
static size_t
ngx_http_limit_traffic_rate_share(size_t limit, u_short conn)
{
    size_t  rate;

    rate = limit / conn;
    return rate ? rate : 1;
}


/* The caller holds the zone's slab mutex. */
static ngx_rbtree_node_t *
ngx_http_limit_traffic_rate_lookup(ngx_http_limit_traffic_rate_ctx_t *ctx,
    ngx_str_t *key, uint32_t hash)
{
    ngx_int_t                            rc;
    ngx_rbtree_node_t                   *node, *sentinel;
    ngx_http_limit_traffic_rate_node_t  *lr;

    node = ctx->rbtree->root;
    sentinel = ctx->rbtree->sentinel;

    while (node != sentinel) {

        if (hash < node->key) {
            node = node->left;
            continue;
        }

        if (hash > node->key) {
            node = node->right;
            continue;
        }

        lr = (ngx_http_limit_traffic_rate_node_t *) &node->color;
        rc = ngx_memn2cmp(key->data, lr->data, key->len, (size_t) lr->len);

        if (rc == 0) {
            return node;
        }

        node = (rc < 0) ? node->left : node->right;
    }

    return NULL;
}


static ngx_int_t
ngx_http_limit_traffic_rate_header_filter(ngx_http_request_t *r)
{
    size_t                                  n, rate;
    uint32_t                                hash;
    ngx_str_t                               key;
    ngx_int_t                               status;
    ngx_uint_t                              i;
    ngx_slab_pool_t                        *shpool;
    ngx_rbtree_node_t                      *node;
    ngx_pool_cleanup_t                     *cln;
    ngx_http_limit_traffic_rate_ctx_t      *ctx;
    ngx_http_limit_traffic_rate_node_t     *lr;
    ngx_http_limit_traffic_rate_conf_t     *lrcf;
    ngx_http_limit_traffic_rate_limit_t    *limits;
    ngx_http_limit_traffic_rate_cleanup_t  *lrcln;
    ngx_http_limit_traffic_rate_req_ctx_t  *rctx;

    if (r != r->main || r->header_sent) {
        return ngx_http_next_header_filter(r);
    }

    rctx = ngx_http_get_module_ctx(r,
                                   ngx_http_limit_traffic_rate_filter_module);

    /* Error responses can clear contexts while retaining pool cleanups. */
    if (rctx == NULL && (r->internal || r->filter_finalize)) {
        for (cln = r->pool->cleanup; cln; cln = cln->next) {
            if (cln->handler != ngx_http_limit_traffic_rate_cleanup) {
                continue;
            }

            rctx = cln->data;

            if (rctx->request == r) {
                ngx_http_set_ctx(r, rctx,
                                 ngx_http_limit_traffic_rate_filter_module);
                break;
            }

            rctx = NULL;
        }
    }

    if (rctx != NULL && rctx->limits.nelts != 0) {
        ngx_http_limit_traffic_rate_cleanup(rctx);
        r->limit_rate = 0;
        r->limit_rate_set = 0;
    }

    if ((rctx != NULL && rctx->skip)
        || r->header_only
        || r->method == NGX_HTTP_HEAD
        || r->headers_out.status < NGX_HTTP_OK
        || r->headers_out.status == NGX_HTTP_NO_CONTENT
        || r->headers_out.status == NGX_HTTP_NOT_MODIFIED
        || r->headers_out.content_length_n == 0)
    {
        return ngx_http_next_header_filter(r);
    }

    lrcf =
        ngx_http_get_module_loc_conf(r,
                                     ngx_http_limit_traffic_rate_filter_module);

    if (lrcf->limits.nelts == 0) {
        return ngx_http_next_header_filter(r);
    }

    if (rctx == NULL) {
        n = sizeof(ngx_http_limit_traffic_rate_req_ctx_t);
        cln = ngx_pool_cleanup_add(r->pool, n);
        if (cln == NULL) {
            return NGX_ERROR;
        }

        rctx = cln->data;
        rctx->request = r;
        rctx->skip = 0;

        if (ngx_array_init(&rctx->limits, r->pool, lrcf->limits.nelts,
                           sizeof(ngx_http_limit_traffic_rate_cleanup_t))
            != NGX_OK)
        {
            return NGX_ERROR;
        }

        cln->handler = ngx_http_limit_traffic_rate_cleanup;
        ngx_http_set_ctx(r, rctx, ngx_http_limit_traffic_rate_filter_module);
    }

    status = NGX_HTTP_INTERNAL_SERVER_ERROR;
    limits = lrcf->limits.elts;

    for (i = 0; i < lrcf->limits.nelts; i++) {

#if (NGX_EXPR)
        rate = ngx_http_get_expr_size_value(r, limits[i].rates);
#else
        rate = limits[i].rate;
#endif

        if (rate == 0 || rate == NGX_CONF_UNSET_SIZE) {
            continue;
        }

        ctx = limits[i].shm_zone->data;

        if (ngx_http_complex_value(r, &ctx->key, &key) != NGX_OK) {
            goto failed;
        }

        if (key.len == 0) {
            continue;
        }

        if (key.len > 1024) {
            ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                          "limit_traffic_rate: key \"%V\" exceeds 1024 bytes",
                          &ctx->key.value);
            continue;
        }

        /* Allocate request state before taking the shared-memory lock. */
        lrcln = ngx_array_push(&rctx->limits);
        if (lrcln == NULL) {
            goto failed;
        }

        lrcln->shm_zone = limits[i].shm_zone;
        lrcln->node = NULL;
        lrcln->limit = rate;

        hash = ngx_crc32_short(key.data, key.len);
        shpool = (ngx_slab_pool_t *) limits[i].shm_zone->shm.addr;

        ngx_shmtx_lock(&shpool->mutex);

        node = ngx_http_limit_traffic_rate_lookup(ctx, &key, hash);

        if (node != NULL) {
            lr = (ngx_http_limit_traffic_rate_node_t *) &node->color;

            if (lr->conn == (u_short) -1) {
                ngx_shmtx_unlock(&shpool->mutex);
                status = NGX_HTTP_SERVICE_UNAVAILABLE;
                goto failed;
            }

            lr->conn++;

        } else {
            n = offsetof(ngx_rbtree_node_t, color)
                + offsetof(ngx_http_limit_traffic_rate_node_t, data) + key.len;

            node = ngx_slab_alloc_locked(shpool, n);
            if (node == NULL) {
                ngx_shmtx_unlock(&shpool->mutex);
                status = NGX_HTTP_SERVICE_UNAVAILABLE;
                goto failed;
            }

            lr = (ngx_http_limit_traffic_rate_node_t *) &node->color;
            node->key = hash;
            lr->len = (u_short) key.len;
            lr->conn = 1;

            ngx_memcpy(lr->data, key.data, key.len);
            ngx_rbtree_insert(ctx->rbtree, node);
        }

        lrcln->node = node;

        ngx_log_debug2(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                       "limit traffic rate: %08XD conn=%d", node->key,
                       lr->conn);

        ngx_shmtx_unlock(&shpool->mutex);
    }

    ngx_http_limit_traffic_rate_update(r, rctx);

    return ngx_http_next_header_filter(r);

failed:

    ngx_http_limit_traffic_rate_cleanup(rctx);
    rctx->skip = 1;

    /* The cleanup record preserves the skip flag across context resets. */
    return ngx_http_filter_finalize_request(r, NULL, status);
}


/* Refresh shares selected while filtering the main response headers. */
static ngx_int_t
ngx_http_limit_traffic_rate_body_filter(ngx_http_request_t *r, ngx_chain_t *in)
{
    ngx_http_limit_traffic_rate_req_ctx_t  *ctx;

    if (r != r->main) {
        return ngx_http_next_body_filter(r, in);
    }

    ctx = ngx_http_get_module_ctx(r, ngx_http_limit_traffic_rate_filter_module);

    if (ctx != NULL) {
        ngx_http_limit_traffic_rate_update(r, ctx);
    }

    return ngx_http_next_body_filter(r, in);
}


static void
ngx_http_limit_traffic_rate_update(ngx_http_request_t *r,
    ngx_http_limit_traffic_rate_req_ctx_t *ctx)
{
    size_t                                  rate, share;
    ngx_uint_t                              i;
    ngx_slab_pool_t                        *shpool;
    ngx_http_limit_traffic_rate_node_t     *lr;
    ngx_http_limit_traffic_rate_cleanup_t  *limits;

    rate = 0;
    limits = ctx->limits.elts;

    for (i = 0; i < ctx->limits.nelts; i++) {
        shpool = (ngx_slab_pool_t *) limits[i].shm_zone->shm.addr;

        ngx_shmtx_lock(&shpool->mutex);

        lr = (ngx_http_limit_traffic_rate_node_t *) &limits[i].node->color;
        share = ngx_http_limit_traffic_rate_share(limits[i].limit, lr->conn);

        ngx_shmtx_unlock(&shpool->mutex);

        if (rate == 0 || share < rate) {
            rate = share;
        }
    }

    if (rate != 0) {
        r->limit_rate = rate;
        r->limit_rate_set = 1;
    }
}


static void
ngx_http_limit_traffic_rate_cleanup(void *data)
{
    ngx_http_limit_traffic_rate_req_ctx_t  *rctx = data;

    ngx_uint_t                              i;
    ngx_slab_pool_t                        *shpool;
    ngx_rbtree_node_t                      *node;
    ngx_http_limit_traffic_rate_ctx_t      *ctx;
    ngx_http_limit_traffic_rate_node_t     *lr;
    ngx_http_limit_traffic_rate_cleanup_t  *limits;

    limits = rctx->limits.elts;

    for (i = 0; i < rctx->limits.nelts; i++) {
        node = limits[i].node;
        if (node == NULL) {
            continue;
        }

        ctx = limits[i].shm_zone->data;
        shpool = (ngx_slab_pool_t *) limits[i].shm_zone->shm.addr;
        lr = (ngx_http_limit_traffic_rate_node_t *) &node->color;

        ngx_shmtx_lock(&shpool->mutex);

        ngx_log_debug2(NGX_LOG_DEBUG_HTTP, limits[i].shm_zone->shm.log, 0,
                       "limit traffic rate cleanup: %08XD conn=%d", node->key,
                       lr->conn);

        if (--lr->conn == 0) {
            ngx_rbtree_delete(ctx->rbtree, node);
            ngx_slab_free_locked(shpool, node);
        }

        ngx_shmtx_unlock(&shpool->mutex);
    }

    rctx->limits.nelts = 0;
}


static void *
ngx_http_limit_traffic_rate_create_conf(ngx_conf_t *cf)
{
    ngx_http_limit_traffic_rate_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_limit_traffic_rate_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    return conf;
}


static char *
ngx_http_limit_traffic_rate_merge_conf(ngx_conf_t *cf, void *parent,
    void *child)
{
    ngx_http_limit_traffic_rate_conf_t  *prev = parent;
    ngx_http_limit_traffic_rate_conf_t  *conf = child;

    ngx_uint_t                           i, j;
    ngx_http_limit_traffic_rate_limit_t  *limits, *plimits, *limit;

#if (NGX_EXPR)
    ngx_array_t                         *rates;
#endif

    if (conf->limits.nelts == 0) {
        conf->limits = prev->limits;
        return NGX_CONF_OK;
    }

    limits = conf->limits.elts;
    plimits = prev->limits.elts;

#if (NGX_EXPR)

    for (i = 0; i < conf->limits.nelts; i++) {
        rates = NULL;

        for (j = 0; j < prev->limits.nelts; j++) {
            if (limits[i].shm_zone == plimits[j].shm_zone) {
                rates = plimits[j].rates;
                break;
            }
        }

        if (ngx_conf_merge_expr_size_value(cf, &limits[i].rates, rates, 0)
            != NGX_OK)
        {
            return NGX_CONF_ERROR;
        }
    }

#endif

    for (i = 0; i < prev->limits.nelts; i++) {
        limits = conf->limits.elts;

        for (j = 0; j < conf->limits.nelts; j++) {
            if (limits[j].shm_zone == plimits[i].shm_zone) {
                break;
            }
        }

        if (j != conf->limits.nelts) {
            continue;
        }

        limit = ngx_array_push(&conf->limits);
        if (limit == NULL) {
            return NGX_CONF_ERROR;
        }

        *limit = plimits[i];
    }

    return NGX_CONF_OK;
}


static void
ngx_http_limit_traffic_rate_rbtree_insert_value(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel)
{
    ngx_rbtree_node_t                  **p;
    ngx_http_limit_traffic_rate_node_t  *lrn, *lrnt;

    for ( ;; ) {

        if (node->key < temp->key) {
            p = &temp->left;

        } else if (node->key > temp->key) {
            p = &temp->right;

        } else {
            lrn = (ngx_http_limit_traffic_rate_node_t *) &node->color;
            lrnt = (ngx_http_limit_traffic_rate_node_t *) &temp->color;

            p = (ngx_memn2cmp(lrn->data, lrnt->data, lrn->len, lrnt->len) < 0)
                ? &temp->left : &temp->right;
        }

        if (*p == sentinel) {
            break;
        }

        temp = *p;
    }

    *p = node;
    node->parent = temp;
    node->left = sentinel;
    node->right = sentinel;
    ngx_rbt_red(node);
}


static ngx_int_t
ngx_http_limit_traffic_rate_init_zone(ngx_shm_zone_t *shm_zone, void *data)
{
    ngx_http_limit_traffic_rate_ctx_t  *octx = data;

    size_t                              len;
    ngx_slab_pool_t                    *shpool;
    ngx_rbtree_node_t                  *sentinel;
    ngx_http_limit_traffic_rate_ctx_t  *ctx;

    ctx = shm_zone->data;

    if (octx) {
        if (ctx->key.value.len != octx->key.value.len
            || ngx_strncmp(ctx->key.value.data, octx->key.value.data,
                           ctx->key.value.len)
               != 0)
        {
            ngx_log_error(NGX_LOG_EMERG, shm_zone->shm.log, 0,
                          "limit_traffic_rate_zone \"%V\" uses key "
                          "\"%V\" but previously used \"%V\"",
                          &shm_zone->shm.name, &ctx->key.value,
                          &octx->key.value);
            return NGX_ERROR;
        }

        ctx->rbtree = octx->rbtree;
        return NGX_OK;
    }

    shpool = (ngx_slab_pool_t *) shm_zone->shm.addr;

    if (shm_zone->shm.exists) {
        ctx->rbtree = shpool->data;
        return NGX_OK;
    }

    ctx->rbtree = ngx_slab_alloc(shpool, sizeof(ngx_rbtree_t));
    if (ctx->rbtree == NULL) {
        return NGX_ERROR;
    }

    shpool->data = ctx->rbtree;

    sentinel = ngx_slab_alloc(shpool, sizeof(ngx_rbtree_node_t));
    if (sentinel == NULL) {
        return NGX_ERROR;
    }

    ngx_rbtree_init(ctx->rbtree, sentinel,
                    ngx_http_limit_traffic_rate_rbtree_insert_value);

    len = sizeof(" in limit_traffic_rate_zone \"\"") + shm_zone->shm.name.len;

    shpool->log_ctx = ngx_slab_alloc(shpool, len);
    if (shpool->log_ctx == NULL) {
        return NGX_ERROR;
    }

    ngx_sprintf(shpool->log_ctx, " in limit_traffic_rate_zone \"%V\"%Z",
                &shm_zone->shm.name);

    return NGX_OK;
}


static char *
ngx_http_limit_traffic_rate_zone(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    u_char                             *p;
    ssize_t                             size;
    ngx_str_t                          *value, name, s;
    ngx_shm_zone_t                     *shm_zone;
    ngx_http_limit_traffic_rate_ctx_t  *ctx;
    ngx_http_compile_complex_value_t    ccv;

    value = cf->args->elts;

    if (ngx_strncmp(value[2].data, "zone=", 5) != 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid parameter \"%V\"", &value[2]);
        return NGX_CONF_ERROR;
    }

    name.data = value[2].data + 5;
    p = (u_char *) ngx_strchr(name.data, ':');

    if (p == NULL) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid zone size \"%V\"", &value[2]);
        return NGX_CONF_ERROR;
    }

    name.len = p - name.data;

    if (name.len == 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid zone name \"%V\"", &value[2]);
        return NGX_CONF_ERROR;
    }

    s.data = p + 1;
    s.len = value[2].data + value[2].len - s.data;
    size = ngx_parse_size(&s);

    if (size == NGX_ERROR) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid zone size \"%V\"", &value[2]);
        return NGX_CONF_ERROR;
    }

    if (size < (ssize_t) (8 * ngx_pagesize)) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "zone \"%V\" is too small", &value[2]);
        return NGX_CONF_ERROR;
    }

    ctx = ngx_pcalloc(cf->pool, sizeof(ngx_http_limit_traffic_rate_ctx_t));
    if (ctx == NULL) {
        return NGX_CONF_ERROR;
    }

    ngx_memzero(&ccv, sizeof(ngx_http_compile_complex_value_t));

    ccv.cf = cf;
    ccv.value = &value[1];
    ccv.complex_value = &ctx->key;

    if (ngx_http_compile_complex_value(&ccv) != NGX_OK) {
        return NGX_CONF_ERROR;
    }

    shm_zone =
        ngx_shared_memory_add(cf, &name, size,
                              &ngx_http_limit_traffic_rate_filter_module);
    if (shm_zone == NULL) {
        return NGX_CONF_ERROR;
    }

    if (shm_zone->data) {
        ctx = shm_zone->data;
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "%V \"%V\" is already bound to key \"%V\"",
                           &cmd->name, &name, &ctx->key.value);
        return NGX_CONF_ERROR;
    }

    shm_zone->init = ngx_http_limit_traffic_rate_init_zone;
    shm_zone->data = ctx;

    return NGX_CONF_OK;
}


static char *
ngx_http_limit_traffic_rate(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_limit_traffic_rate_conf_t  *lrcf = conf;

    ssize_t                               n;
    size_t                                value_rate;
    ngx_str_t                            *value, name, s;
    ngx_uint_t                            i;
    ngx_shm_zone_t                       *shm_zone;
    ngx_http_limit_traffic_rate_limit_t  *limits, *limit;

#if (NGX_EXPR)
    ngx_expr_when_id_t                    expr_id;
    ngx_conf_expr_size_ctx_t             *rate;
#endif

    value = cf->args->elts;
    value_rate = 0;
    ngx_str_null(&name);

    for (i = 1; i < cf->args->nelts; i++) {

        if (ngx_strncmp(value[i].data, "zone=", 5) == 0) {
            if (name.data != NULL) {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "duplicate parameter \"%V\"", &value[i]);
                return NGX_CONF_ERROR;
            }

            name.data = value[i].data + 5;
            name.len = value[i].len - 5;

            if (name.len == 0) {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "invalid zone name \"%V\"", &value[i]);
                return NGX_CONF_ERROR;
            }

            continue;
        }

        if (ngx_strncmp(value[i].data, "rate=", 5) == 0) {
            if (value_rate != 0) {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "duplicate parameter \"%V\"", &value[i]);
                return NGX_CONF_ERROR;
            }

            s.data = value[i].data + 5;
            s.len = value[i].len - 5;
            n = ngx_parse_size(&s);

            if (n == NGX_ERROR || n == 0) {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "invalid rate \"%V\"", &value[i]);
                return NGX_CONF_ERROR;
            }

            value_rate = n;
            continue;
        }

        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid parameter \"%V\"", &value[i]);
        return NGX_CONF_ERROR;
    }

    shm_zone =
        ngx_shared_memory_add(cf, &name, 0,
                              &ngx_http_limit_traffic_rate_filter_module);
    if (shm_zone == NULL) {
        return NGX_CONF_ERROR;
    }

    if (lrcf->limits.elts == NULL) {
        if (ngx_array_init(&lrcf->limits, cf->pool, 1,
                           sizeof(ngx_http_limit_traffic_rate_limit_t))
            != NGX_OK)
        {
            return NGX_CONF_ERROR;
        }
    }

    limits = lrcf->limits.elts;

    for (i = 0; i < lrcf->limits.nelts; i++) {
        if (limits[i].shm_zone == shm_zone) {
            break;
        }
    }

    if (i == lrcf->limits.nelts) {
        limit = ngx_array_push(&lrcf->limits);
        if (limit == NULL) {
            return NGX_CONF_ERROR;
        }

        limit->shm_zone = shm_zone;

#if (NGX_EXPR)
        limit->rates = ngx_array_create(cf->pool, 1,
                                        sizeof(ngx_conf_expr_size_ctx_t));
        if (limit->rates == NULL) {
            return NGX_CONF_ERROR;
        }
#endif

    } else {
        limit = &limits[i];

#if !(NGX_EXPR)
        return "is duplicate";
#endif

    }

#if (NGX_EXPR)

    expr_id = ngx_expr_get_associated_when_id(cf);

    if (ngx_expr_find_ctx(limit->rates, expr_id,
                          sizeof(ngx_conf_expr_size_ctx_t),
                          offsetof(ngx_conf_expr_size_ctx_t, expr_id))
        != NULL)
    {
        return "is duplicate";
    }

    rate = ngx_array_push(limit->rates);
    if (rate == NULL) {
        return NGX_CONF_ERROR;
    }

    rate->value = value_rate;
    rate->expr_id = expr_id;

#else

    limit->rate = value_rate;

#endif

    return NGX_CONF_OK;
}


static ngx_int_t
ngx_http_limit_traffic_rate_init(ngx_conf_t *cf)
{
    ngx_http_next_header_filter = ngx_http_top_header_filter;
    ngx_http_top_header_filter = ngx_http_limit_traffic_rate_header_filter;

    ngx_http_next_body_filter = ngx_http_top_body_filter;
    ngx_http_top_body_filter = ngx_http_limit_traffic_rate_body_filter;

    return NGX_OK;
}
