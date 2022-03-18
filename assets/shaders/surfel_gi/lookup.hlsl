#ifndef SURFEL_GI_LOOKUP_HLSL
#define SURFEL_GI_LOOKUP_HLSL

#include "surfel_grid_hash.hlsl"

struct SurfRcacheLookup {
    uint entry_idx[8];
    float weight[8];
    uint count;
};

SurfRcacheLookup surf_rcache_trilinear_lookup(float3 pt_ws) {
    const float3 eye_pos = get_eye_position();

    const int3 grid_coord = surfel_pos_to_grid_coord(pt_ws.xyz, eye_pos);
    const uint4 grid_c4 = surfel_grid_coord_to_c4(grid_coord);
    const uint cascade = grid_c4.w;

    const int3 coord_within_cascade = surfel_grid_coord_within_cascade(grid_coord, cascade);
    const float3 center_cell_offset = pt_ws - surfel_grid_coord_center(grid_c4, eye_pos);
    const float cell_diameter = surfel_grid_cell_diameter_in_cascade(cascade);
    const int3 c0 = coord_within_cascade + (center_cell_offset > 0.0.xxx ? (0).xxx : (-1).xxx);
    const float3 interp_t0 = center_cell_offset > 0.0.xxx ? 0.0.xxx : 1.0.xxx;

    float weight_sum = 0.0;
    SurfRcacheLookup result;
    result.count = 0;

    for (int z = 0; z < 2; ++z) {
        for (int y = 0; y < 2; ++y) {
            for (int x = 0; x < 2; ++x) {
                const int3 sample_within_cascade = c0 + int3(x, y, z);
                const uint4 sample_c4 = uint4(
                    clamp(sample_within_cascade, (int3)0, (int3)(SURFEL_CS - 1)),
                    cascade);
    
                const uint cell_idx = surfel_grid_c4_to_hash(sample_c4);
                const uint4 cell_meta = surf_rcache_grid_meta_buf.Load4(sizeof(uint4) * cell_idx);
                const uint entry_idx = cell_meta.x;

                result.weight[result.count] = 0;

                if (cell_meta.y & SURF_RCACHE_ENTRY_META_OCCUPIED) {
                    float3 interp = center_cell_offset / cell_diameter + interp_t0;
                    interp = saturate((int3(x, y, z) == 0 ? ((1).xxx - interp) : interp));

                    const float weight = interp.x * interp.y * interp.z;
                    result.entry_idx[result.count] = entry_idx;
                    result.weight[result.count] = weight;
                    result.count += 1;
                    weight_sum += weight;
                }
            }
        }
    }

    for (uint i = 0; i < result.count; ++i) {
        result.weight[i] /= max(1e-10, weight_sum);
    }

    return result;
}

SurfRcacheLookup surf_rcache_nearest_lookup(float3 pt_ws) {
    SurfRcacheLookup result;
    result.count = 0;

    const float3 eye_pos = get_eye_position();
    const int3 grid_coord = surfel_pos_to_grid_coord(pt_ws.xyz, eye_pos);
    const uint4 grid_c4 = surfel_grid_coord_to_c4(grid_coord);
    const uint cascade = grid_c4.w;

    const uint cell_idx = surfel_grid_coord_to_hash(grid_coord);
    const uint4 cell_meta = surf_rcache_grid_meta_buf.Load4(sizeof(uint4) * cell_idx);

    if (cell_meta.y & SURF_RCACHE_ENTRY_META_OCCUPIED) {
        const uint entry_idx = cell_meta.x;
        result.entry_idx[result.count] = entry_idx;
        result.weight[result.count] = 1;
        result.count += 1;
    }

    return result;
}

#if SURF_RCACHE_USE_TRILINEAR
    #define surf_rcache_lookup surf_rcache_trilinear_lookup
#else
    #define surf_rcache_lookup surf_rcache_nearest_lookup
#endif

float3 lookup_surfel_gi(float3 pt_ws, float3 normal_ws, uint query_rank) {
#ifndef SURFEL_LOOKUP_DONT_KEEP_ALIVE
    if (!FREEZE_SURFEL_SET) {
        // TODO: should be prev eye pos for the find_missing_surfels shader
        const float3 eye_pos = get_eye_position();

        const uint cell_idx = surfel_grid_coord_to_hash(surfel_pos_to_grid_coord(pt_ws.xyz, eye_pos));

        const uint4 cell_meta = surf_rcache_grid_meta_buf.Load4(sizeof(uint4) * cell_idx);
        uint entry_idx = cell_meta.x;
        const uint entry_flags = cell_meta.y;

        if ((entry_flags & SURF_RCACHE_ENTRY_META_OCCUPIED) == 0) {
            // Allocate

            uint prev = 0;
            surf_rcache_grid_meta_buf.InterlockedOr(sizeof(uint4) * cell_idx + sizeof(uint), SURF_RCACHE_ENTRY_META_OCCUPIED, prev);

            if ((prev & SURF_RCACHE_ENTRY_META_OCCUPIED) == 0) {
                // We've allocated it!

                uint alloc_idx;
                surf_rcache_meta_buf.InterlockedAdd(SURFEL_META_ALLOC_COUNT, 1, alloc_idx);

                entry_idx = surf_rcache_pool_buf[alloc_idx];
                surf_rcache_meta_buf.InterlockedMax(SURFEL_META_ENTRY_COUNT, entry_idx + 1);

                // Clear dead state, mark used.
                surf_rcache_life_buf[entry_idx] = surfel_life_for_rank(query_rank);
                surf_rcache_entry_cell_buf[entry_idx] = cell_idx;

                surf_rcache_grid_meta_buf.Store(sizeof(uint4) * cell_idx + 0, entry_idx);
            } else {
                // We did not allocate it, so read the entry index from whoever did.
                
                entry_idx = surf_rcache_grid_meta_buf.Load(sizeof(uint4) * cell_idx + 0);
            }
        }
    }
#endif

    SurfRcacheLookup lookup = surf_rcache_lookup(pt_ws);

    Vertex new_surfel;
    new_surfel.position = pt_ws.xyz;
    new_surfel.normal = normal_ws;

    float3 irradiance_sum = 0.0.xxx;

    for (uint i = 0; i < lookup.count; ++i) {
        const uint entry_idx = lookup.entry_idx[i];
        const float3 irradiance = surf_rcache_irradiance_buf[entry_idx].xyz;
        irradiance_sum += irradiance * lookup.weight[i];

        if (!FREEZE_SURFEL_SET) {
            #ifndef SURFEL_LOOKUP_DONT_KEEP_ALIVE
                if (surf_rcache_life_buf[entry_idx] < SURFEL_LIFE_RECYCLE) {
                    uint prev_life;
                    InterlockedMin(surf_rcache_life_buf[entry_idx], surfel_life_for_rank(query_rank), prev_life);

                    const uint prev_rank = surfel_life_to_rank(prev_life);
                    if (query_rank <= prev_rank) {
                        surf_rcache_reposition_proposal_buf[entry_idx] = pack_vertex(new_surfel);
                    }
                }
            #endif
        }
    }

    return irradiance_sum;
}

#endif // SURFEL_GI_LOOKUP_HLSL
