#include "Solver.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Public simulator using actual tile values. dir: left/right/down/up.
int solver_move(const int32_t *in, int dir, int32_t *out) {
    if (dir < 0 || dir > 3) return 0;
    memcpy(out, in, 16 * sizeof(*out));

    for (int a = 0; a < 4; a++) {
        int pos[4], line[4] = {0}, n = 0;

        // Collect the line in the direction of travel, skipping empty cells.
        for (int i = 0; i < 4; i++) {
            int x, y;
            if (dir == 0 || dir == 1) {
                x = dir == 0 ? i : 3 - i;
                y = a;
            } else {
                x = a;
                y = dir == 2 ? i : 3 - i;
            }
            pos[i] = x + 4 * y;
            if (in[pos[i]]) line[n++] = in[pos[i]];
        }

        // Merge equal neighbours once, then pack the result against the far edge.
        int merged[4] = {0}, m = 0;
        for (int i = 0; i < n; i++) {
            int v = line[i];
            if (i + 1 < n && v == line[i + 1] && v <= INT32_MAX / 2) {
                v *= 2;
                i++;
            }
            merged[m++] = v;
        }
        for (int i = 0; i < 4; i++) out[pos[i]] = merged[i];
    }

    return memcmp(in, out, 16 * sizeof(*out)) != 0;
}

// Search size. DEPTH is the shallowest lookahead; the search then deepens one
// ply at a time, as long as the node budget is not spent: cramped boards have a
// small tree, so the endgame gets read further ahead without a per-move time
// spike. The defaults are the shipping values; they are macros so that a
// benchmark can build a cheaper solver (-DDEPTH=3 -DNODE_BUDGET=25000) and
// compare evaluation weights without waiting minutes per game.
#ifndef DEPTH
#define DEPTH 4
#endif
#ifndef MAX_DEPTH
#define MAX_DEPTH 6
#endif
#ifndef NODE_BUDGET
#define NODE_BUDGET 200000 // board nodes per move; deeper costs more time
#endif
#ifndef SAMPLE_CELLS
#define SAMPLE_CELLS 4
#endif
#ifndef MERGE_MAX_BONUS
#define MERGE_MAX_BONUS 1500
#endif
#ifndef MERGE_MAX_FROM
#define MERGE_MAX_FROM 9
#endif
// Cramped boards have a small tree, so the endgame can be read much further
// ahead for very little extra time - and that is where a wrong move ends the
// game. These three settings widen the search once few cells are free.
#ifndef ENDGAME_EMPTY
#define ENDGAME_EMPTY 4 // free cells at which the wider endgame search starts
#endif
// 8,192 を作ったあとの探索を広げる倍率。端末は 1 手 0.14 秒のうち 0.06 秒しか
// 使っていないので、大きいタイルができてから余っている時間を使う。1 = 無効。
#ifndef BIG_TILE_BUDGET_MULT
#define BIG_TILE_BUDGET_MULT 1
#endif
// log2 でのしきい値。13 = 8,192。
#ifndef BIG_TILE_FROM
#define BIG_TILE_FROM 13
#endif

#ifndef ENDGAME_BUDGET_MULT
#define ENDGAME_BUDGET_MULT 4
#endif
#ifndef ENDGAME_MAX_DEPTH
#define ENDGAME_MAX_DEPTH 8
#endif

#ifndef CACHE_BITS
#define CACHE_BITS 15
#endif
enum {
    CACHE_SIZE = 1 << CACHE_BITS
};

typedef struct {
    uint64_t hash;
    uint8_t b[16];
    uint8_t depth, kind, used;
    double value;
} Entry;

typedef struct {
    Entry *cache;
    long nodes;
} Search;

// 0 = the game may spawn 2 or 4 (90% / 10%); 2 or 4 = only that value appears.
static int32_t spawnValue;

// 出現するマスの出やすさ。NULL なら一様 (空きマスから等確率)。
static const int32_t *spawnWeights;

void solver_set_spawn_value(int32_t v) {
    spawnValue = (v == 2 || v == 4) ? v : 0;
}

int32_t solver_spawn_value(void) {
    return spawnValue;
}

void solver_set_spawn_weights(const int32_t *weights) {
    spawnWeights = weights;
}

static uint64_t hashboard(const uint8_t b[16], int depth, int kind) {
    uint64_t h = 1469598103934665603ULL;
    for (int i = 0; i < 16; i++) {
        h ^= (uint64_t)b[i] + (uint64_t)(i * 37);
        h *= 1099511628211ULL;
    }
    h ^= (unsigned)(depth * 2 + kind) ^ (unsigned)spawnValue * 8u ^ (spawnWeights ? 0x5bd1e995u : 0u);
    h *= 1099511628211ULL;
    return h;
}

static int lookup(Search *s, const uint8_t b[16], int depth, int kind, double *value) {
    if (!s->cache) return 0;
    uint64_t h = hashboard(b, depth, kind);
    Entry *e = &s->cache[h & (CACHE_SIZE - 1)];
    if (e->used && e->hash == h && e->depth == depth && e->kind == kind && !memcmp(e->b, b, 16)) {
        *value = e->value;
        return 1;
    }
    return 0;
}

static void store(Search *s, const uint8_t b[16], int depth, int kind, double value) {
    if (!s->cache) return;
    uint64_t h = hashboard(b, depth, kind);
    Entry *e = &s->cache[h & (CACHE_SIZE - 1)];
    e->hash = h;
    memcpy(e->b, b, 16);
    e->depth = (uint8_t)depth;
    e->kind = (uint8_t)kind;
    e->used = 1;
    e->value = value;
}

// Tiles are stored as exponents (0 = empty) inside the search.
static int move_rank(const uint8_t in[16], int dir, uint8_t out[16]) {
    memcpy(out, in, 16);

    for (int a = 0; a < 4; a++) {
        int pos[4], n = 0, m = 0;
        uint8_t line[4] = {0}, dest[4] = {0};

        for (int i = 0; i < 4; i++) {
            int x, y;
            if (dir < 2) {
                x = dir == 0 ? i : 3 - i;
                y = a;
            } else {
                x = a;
                y = dir == 2 ? i : 3 - i;
            }
            pos[i] = x + 4 * y;
            if (in[pos[i]]) line[n++] = in[pos[i]];
        }

        for (int i = 0; i < n; i++) {
            uint8_t v = line[i];
            if (i + 1 < n && v == line[i + 1] && v < 30) {
                v++;
                i++;
            }
            dest[m++] = v;
        }
        for (int i = 0; i < 4; i++) out[pos[i]] = dest[i];
    }

    return memcmp(in, out, 16) != 0;
}

#ifndef W_EMPTY
#define W_EMPTY 260.0
#endif
#ifndef W_OPEN
#define W_OPEN 200.0
#endif
#ifndef W_EMPTY_TIGHT
#define W_EMPTY_TIGHT 1.0
#endif
#ifndef W_OPEN_TIGHT
#define W_OPEN_TIGHT 1.0
#endif
#ifndef W_MONO
#define W_MONO 22.0
#endif
#ifndef W_SMOOTH
#define W_SMOOTH 5.0
#endif
#ifndef W_MERGE
#define W_MERGE 18.0
#endif
#ifndef W_SNAKE
#define W_SNAKE 1.5
#endif
#ifndef W_CORNER
#define W_CORNER 30.0
#endif

// Rotated and reflected snake ordering. The best orientation may change as the
// board changes; no fixed corner is artificially enforced.
static double evaluate(const uint8_t b[16]) {
    static const double w[16] = {1.0,     .72,   .5184,  .3732,  .2687, .1935, .1393, .1003,
                                 .0722,   .0520, .0374,  .0269,  .0194, .0140, .0101, .0072};
    int empty = 0, highest = 0;
    double smooth = 0, mono = 0, merge = 0, bestSnake = 0;

    for (int i = 0; i < 16; i++) {
        if (!b[i]) empty++;
        if (b[i] > highest) highest = b[i];
    }

    // Monotonicity and smoothness along rows and columns.
    for (int axis = 0; axis < 2; axis++)
        for (int a = 0; a < 4; a++) {
            int prev = -1;
            double asc = 0, desc = 0;
            for (int k = 0; k < 4; k++) {
                int idx = axis ? (a + 4 * k) : (k + 4 * a), v = b[idx];
                if (!v) continue;
                if (prev >= 0) {
                    int delta = v - prev;
                    if (delta > 0) asc += delta;
                    else desc -= delta;
                    smooth -= fabs((double)delta);
                    // Weight by tile size: keeping two 1024s next to each other
                    // matters far more than keeping two 2s.
                    if (delta == 0) merge += v;
                }
                prev = v;
            }
            mono -= fmin(asc, desc);
        }

    // Snake weight for all 8 symmetries (rotations and reflections).
    for (int trans = 0; trans < 8; trans++) {
        double sum = 0;
        for (int i = 0; i < 16; i++) {
            int y = i / 4, x = (y & 1) ? 3 - (i % 4) : i % 4;
            if (trans & 1) x = 3 - x;
            if (trans & 2) y = 3 - y;
            if (trans & 4) {
                int t = x;
                x = y;
                y = t;
            }
            int v = b[x + 4 * y];
            sum += w[i] * v * v * v;
        }
        if (sum > bestSnake) bestSnake = sum;
    }

    // Space you can use: empty cells that touch another empty cell. A single
    // isolated hole gives the board no room to shuffle, so it is worth less
    // than an empty cell next to free space.
    int open = 0;
    for (int y = 0; y < 4; y++)
        for (int x = 0; x < 4; x++) {
            if (b[x + 4 * y]) continue;
            if ((x > 0 && !b[x - 1 + 4 * y]) || (x < 3 && !b[x + 1 + 4 * y]) ||
                (y > 0 && !b[x + 4 * (y - 1)]) || (y < 3 && !b[x + 4 * (y + 1)]))
                open++;
        }

    int corner = highest && (b[0] == highest || b[3] == highest || b[12] == highest || b[15] == highest);

    // Weights are macros so a benchmark can compare variants.
    double wEmpty = W_EMPTY, wOpen = W_OPEN;
    if (empty <= 3) {
        // Late game: free space is worth much more than the counts suggest,
        // because the next spawn can end the game.
        wEmpty *= W_EMPTY_TIGHT;
        wOpen *= W_OPEN_TIGHT;
    }
    return empty * wEmpty + open * wOpen + mono * W_MONO + smooth * W_SMOOTH + merge * W_MERGE +
           bestSnake * W_SNAKE + (corner ? highest * W_CORNER : 0.0);
}

static double player(Search *s, const uint8_t b[16], int depth);

// Chance node: sample the tiles the game may spawn, weighted 90% / 10%.
static double chance(Search *s, uint8_t b[16], int depth) {
    s->nodes++;
    double cached;
    if (lookup(s, b, depth, 1, &cached)) return cached;

    int freepos[16], n = 0;
    for (int i = 0; i < 16; i++)
        if (!b[i]) freepos[n++] = i;
    if (!n) return player(s, b, depth);

    int samples = n < SAMPLE_CELLS ? n : SAMPLE_CELLS;
    // When empties exceed four, sample four roughly evenly-spaced positions.
    // Board-derived rotation avoids always favoring a particular edge.
    uint64_t h = hashboard(b, depth, 1);
    int offset = (int)(h % (unsigned)n);
    // 実測の出現分布があるときは、空きマスを等確率ではなく重み付きで層化抽出する。
    // 層の中の位置は盤面ハッシュでずらし、毎回同じマスだけを見ないようにする。
    int picked[SAMPLE_CELLS];
    if (spawnWeights) {
        uint32_t cum[16], total = 0;
        for (int j = 0; j < n; j++) {
            int32_t w = spawnWeights[freepos[j]];
            total += (uint32_t)(w > 0 ? w : 1);
            cum[j] = total;
        }
        uint32_t base = (uint32_t)(h % total);
        for (int j = 0; j < samples; j++) {
            uint32_t target = (uint32_t)(((uint64_t)base + ((uint64_t)total * (2 * j + 1)) / (2 * samples)) % total);
            int k = 0;
            while (cum[k] <= target) k++;
            picked[j] = freepos[k];
        }
    } else {
        for (int j = 0; j < samples; j++) picked[j] = freepos[(offset + (j * n) / samples) % n];
    }
    double sum = 0;
    for (int j = 0; j < samples; j++) {
        int at = picked[j];
        if (spawnValue) {
            b[at] = spawnValue == 4 ? 2 : 1;
            sum += player(s, b, depth);
        } else {
            b[at] = 1;
            sum += .9 * player(s, b, depth);
            b[at] = 2;
            sum += .1 * player(s, b, depth);
        }
        b[at] = 0;
    }

    double out = sum / samples;
    store(s, b, depth, 1, out);
    return out;
}

// Player node: expectimax over the four legal moves.
static double player(Search *s, const uint8_t b[16], int depth) {
    s->nodes++;
    if (depth == 0) return evaluate(b);

    double cached;
    if (lookup(s, b, depth, 0, &cached)) return cached;

    double best = -1e100;
    uint8_t next[16];
    for (int d = 0; d < 4; d++)
        if (move_rank(b, d, next)) {
            double v = chance(s, next, depth - 1);
            if (v > best) best = v;
        }
    if (best < -1e90) best = evaluate(b) - 100000.0;

    store(s, b, depth, 0, best);
    return best;
}

// Returns the best direction (0..3), or -1 when no move is legal.
int solver_best(const int32_t *in) {
    uint8_t b[16];
    for (int i = 0; i < 16; i++) {
        int32_t v = in[i];
        if (v < 0 || (v && (v & (v - 1)))) return -1;
        uint8_t r = 0;
        while (v > 1) {
            r++;
            v >>= 1;
        }
        if (in[i] && !r) return -1;
        b[i] = r;
    }

    int highest = 0;
    for (int i = 0; i < 16; i++)
        if (b[i] > highest) highest = b[i];

    int empty = 0;
    for (int i = 0; i < 16; i++)
        if (!b[i]) empty++;

    long budget = NODE_BUDGET;
    int maxDepth = MAX_DEPTH;
    if (ENDGAME_EMPTY > 0 && empty <= ENDGAME_EMPTY) {
        budget *= ENDGAME_BUDGET_MULT;
        if (ENDGAME_MAX_DEPTH > maxDepth) maxDepth = ENDGAME_MAX_DEPTH;
    }
    if (BIG_TILE_BUDGET_MULT > 1 && highest >= BIG_TILE_FROM) {
        budget *= BIG_TILE_BUDGET_MULT;
        if (ENDGAME_MAX_DEPTH > maxDepth) maxDepth = ENDGAME_MAX_DEPTH;
    }

    Search s = {calloc(CACHE_SIZE, sizeof(Entry)), 0};
    int choice = -1;
    long spent = 0;
    uint8_t next[16];

    // Deepen one ply at a time while the tree stays inside NODE_BUDGET. The
    // node count is deterministic, so the same board always gets the same move.
    for (int depth = DEPTH; depth <= maxDepth; depth++) {
        double best = -1e100;
        int move = -1;
        long before = s.nodes;
        for (int d = 0; d < 4; d++)
            if (move_rank(b, d, next)) {
                double score = chance(&s, next, depth - 1);
                // The static score cannot see that two equal tiles are worth
                // more once joined, so a mergeable pair of 2048s could be left
                // parked until the board jammed. Prefer the move that joins it.
                if (highest >= MERGE_MAX_FROM) {
                    int after = 0;
                    for (int i = 0; i < 16; i++)
                        if (next[i] > after) after = next[i];
                    if (after > highest) score += MERGE_MAX_BONUS;
                }
                if (score > best) {
                    best = score;
                    move = d;
                }
            }
        if (move < 0) break;
        choice = move;
        spent += s.nodes - before;
        // The next ply costs roughly five times this one; stop if it does not fit.
        if ((budget - spent) < 5 * (s.nodes - before)) break;
    }

    free(s.cache);
    return choice;
}
