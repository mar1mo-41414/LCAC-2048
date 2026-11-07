// 簡易シミュレーション。実機のログと同じ形で進捗とマイルストーンを出す。
//
//   simulate [games] [maxmoves] [spawn] [env] [model]
//
//   spawn  0 = 2 / 4 を 90 / 10 で出す、2 または 4 = その値だけ出す (既定 0)
//   env    出現位置の出方。uniform = 空きマスから等確率、measured = 実機の実測分布
//          (Sources/SpawnBias.h)、sharp = その偏りを 2 倍に強めたもの、
//          sharp3 / sharp5 = 3 倍 / 5 倍 (偏りが終盤でもっと強い場合の感度を見る)。
//          既定 uniform
//   model  ソルバーに渡す出現位置の仮定。uniform / measured。既定 uniform
//
// 実機のゲームは 4 固定で遊んでいるので、比較するときは spawn=4・env=measured を使う。
#include "../Sources/Solver.h"
#include "../Sources/SpawnBias.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint32_t state;

static uint32_t rng(void) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

static int fixedValue;
static int measuredEnvironment;
static int biasScale = 1;

// 空きマスに 1 個出す。measuredEnvironment のときは実測の重みで位置を選ぶ。
static void spawn(int32_t b[16]) {
    int cells[16], weight[16], n = 0, total = 0;
    for (int i = 0; i < 16; i++) {
        if (b[i]) continue;
        cells[n] = i;
        int w = 1;
        if (measuredEnvironment) {
            w = 1000 + ((int)kSpawnWeight[i] - 1000) * biasScale;
            if (w < 50) w = 50;
        }
        weight[n] = w;
        total += weight[n];
        n++;
    }
    if (!n) return;
    uint32_t r = rng() % (uint32_t)total;
    int k = 0;
    while (r >= (uint32_t)weight[k]) {
        r -= (uint32_t)weight[k];
        k++;
    }
    int at = cells[k];
    if (fixedValue) {
        b[at] = fixedValue;
    } else {
        b[at] = (rng() % 10 == 0) ? 4 : 2;
    }
}

// 合体で増えたタイルの合計をスコアに足す (ゲームと同じ数え方)。
// count[k] = 2^k のタイルの枚数。k は log2 なので 2 は count[1]、4 は count[2]。
static long addScore(const int32_t *before, const int32_t *after) {
    int beforeCount[32] = {0}, afterCount[32] = {0};
    for (int i = 0; i < 16; i++) {
        for (int v = before[i], k = 0; v > 1; v >>= 1) {
            k++;
            beforeCount[k]++;
        }
        for (int v = after[i], k = 0; v > 1; v >>= 1) {
            k++;
            afterCount[k]++;
        }
    }
    long gained = 0;
    for (int k = 2; k < 31; k++) {
        if (afterCount[k] > beforeCount[k]) gained += (long)(afterCount[k] - beforeCount[k]) << k;
    }
    return gained;
}

static void printBoard(const int32_t b[16]) {
    for (int i = 0; i < 16; i++) printf("%s%d", i ? "," : "", b[i]);
}

static int maxTile(const int32_t b[16]) {
    int m = 0;
    for (int i = 0; i < 16; i++)
        if (b[i] > m) m = b[i];
    return m;
}

int main(int argc, char **argv) {
    int games = argc > 1 ? atoi(argv[1]) : 3;
    int maxmoves = argc > 2 ? atoi(argv[2]) : 5000;
    fixedValue = argc > 3 ? atoi(argv[3]) : 0;
    if (fixedValue != 2 && fixedValue != 4) fixedValue = 0;
    measuredEnvironment = argc > 4 && strcmp(argv[4], "uniform");
    biasScale = argc > 4 && !strcmp(argv[4], "sharp") ? 2 : 1;
    if (argc > 4 && !strcmp(argv[4], "sharp3")) biasScale = 3;
    if (argc > 4 && !strcmp(argv[4], "sharp5")) biasScale = 5;
    int measuredModel = argc > 5 && !strcmp(argv[5], "measured");

    solver_set_spawn_value(fixedValue);
    if (measuredModel) solver_set_spawn_weights(kSpawnWeight);

    printf("# games=%d moves=%d spawn=%d env=%s scale=%d model=%s\n", games, maxmoves, fixedValue,
           measuredEnvironment ? "measured" : "uniform", biasScale, measuredModel ? "measured" : "uniform");
    fflush(stdout);

    for (int g = 1; g <= games; g++) {
        state = 0xabc123u + (uint32_t)g;
        int32_t b[16] = {0}, out[16];
        spawn(b);
        spawn(b);
        int step = 0, best = 0;
        long score = 0;
        clock_t start = clock();
        while (step < maxmoves) {
            int d = solver_best(b);
            if (d < 0) break;
            if (!solver_move(b, d, out)) {
                fprintf(stderr, "illegal move\n");
                return 1;
            }
            score += addScore(b, out);
            for (int i = 0; i < 16; i++) b[i] = out[i];
            spawn(b);
            step++;
            if (step % 500 == 0) {
                printf("  progress moves=%d score=%ld board ", step, score);
                printBoard(b);
                printf("\n");
                fflush(stdout);
            }
            // 実機のログと同じ形: 2048 以上のタイルが増えた時点を残す。
            int m = maxTile(b);
            if (m > best) {
                best = m;
                if (m >= 2048 && !(m & (m - 1))) {
                    printf("  milestone tile=%d score=%ld moves=%d\n", m, score, step);
                    fflush(stdout);
                }
            }
        }
        printf("seed %d max=%d score=%ld moves=%d cpu=%.2fs%s\n", g, maxTile(b), score, step,
               (double)(clock() - start) / CLOCKS_PER_SEC, step == maxmoves ? " capped" : "");
        fflush(stdout);
    }
    return 0;
}
