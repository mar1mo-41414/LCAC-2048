#ifndef SOLVER_H
#define SOLVER_H
#include <stdint.h>
// b[x + 4*y]; direction 0=left, 1=right, 2=down, 3=up.
int solver_move(const int32_t *in, int dir, int32_t *out);
int solver_best(const int32_t *in);
// 0 = the game may spawn 2 or 4; 2 or 4 = only that value appears.
void solver_set_spawn_value(int32_t v);
int32_t solver_spawn_value(void);
#endif
