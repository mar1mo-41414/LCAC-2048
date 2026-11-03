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

// DEPTH is the normal lookahead. When the board has CROWDED_EMPTIES or fewer
// empty cells the search goes one ply deeper: the branching factor is small
// there and that is where the game is decided.
enum {
    DEPTH = 4,
    DEEP_DEPTH = 5,
    CROWDED_EMPTIES = 3,
    CACHE_BITS = 15,
    CACHE_SIZE = 1 << CACHE_BITS,
    SAMPLE_CELLS = 4,
    // Score bonus for a move that joins two copies of the highest tile. Parking
    // such a pair to "keep it for later" is how the board jams up. Only big
    // tiles are forced (512 = 2^9); forcing 2s and 4s to merge early just
    // breaks the snake order.
    MERGE_MAX_BONUS = 1500,
    MERGE_MAX_FROM = 9
};

typedef struct {
    uint64_t hash;
    uint8_t b[16];
    uint8_t depth, kind, used;
    double value;
} Entry;

typedef struct {
    Entry *cache;
} Search;

static uint64_t hashboard(const uint8_t b[16], int depth, int kind) {
    uint64_t h = 1469598103934665603ULL;
    for (int i = 0; i < 16; i++) {
        h ^= (uint64_t)b[i] + (uint64_t)(i * 37);
        h *= 1099511628211ULL;
    }
    h ^= (unsigned)(depth * 2 + kind);
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

    int corner = highest && (b[0] == highest || b[3] == highest || b[12] == highest || b[15] == highest);

    return empty * 260.0 + mono * 22.0 + smooth * 5.0 + merge * 18.0 + bestSnake * 1.5 +
           (corner ? highest * 30.0 : 0.0);
}

static double player(Search *s, const uint8_t b[16], int depth);

// Chance node: sample the tiles the game may spawn, weighted 90% / 10%.
static double chance(Search *s, uint8_t b[16], int depth) {
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
    double sum = 0;
    for (int j = 0; j < samples; j++) {
        int at = freepos[(offset + (j * n) / samples) % n];
        b[at] = 1;
        sum += .9 * player(s, b, depth);
        b[at] = 2;
        sum += .1 * player(s, b, depth);
        b[at] = 0;
    }

    double out = sum / samples;
    store(s, b, depth, 1, out);
    return out;
}

// Player node: expectimax over the four legal moves.
static double player(Search *s, const uint8_t b[16], int depth) {
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
    int empty = 0;
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
        if (!r) empty++;
    }

    int depth = (empty <= CROWDED_EMPTIES) ? DEEP_DEPTH : DEPTH;
    int highest = 0;
    for (int i = 0; i < 16; i++)
        if (b[i] > highest) highest = b[i];

    Search s = {calloc(CACHE_SIZE, sizeof(Entry))};
    double best = -1e100;
    int choice = -1;
    uint8_t next[16];
    for (int d = 0; d < 4; d++)
        if (move_rank(b, d, next)) {
            double score = chance(&s, next, depth - 1);
            // The static score cannot see that two equal tiles are worth more
            // once joined, so a mergeable pair of 2048s could be left parked
            // until the board jammed. Prefer the move that joins the pair.
            if (highest >= MERGE_MAX_FROM) {
                int after = 0;
                for (int i = 0; i < 16; i++)
                    if (next[i] > after) after = next[i];
                if (after > highest) score += MERGE_MAX_BONUS;
            }
            if (score > best) {
                best = score;
                choice = d;
            }
        }
    free(s.cache);
    return choice;
}
