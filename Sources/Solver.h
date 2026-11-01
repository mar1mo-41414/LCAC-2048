#ifndef SOLVER_H
#define SOLVER_H
#include <stdint.h>
// b[x + 4*y]; direction 0=left, 1=right, 2=down, 3=up.
int solver_move(const int32_t *in, int dir, int32_t *out);
int solver_best(const int32_t *in);
#endif
