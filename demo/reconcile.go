package controller

import (
	"context"
	"time"
)

// Reconcile brings the cluster state in line with obj.
func (r *Reconciler) Reconcile(ctx context.Context, obj *Object) error {
	obj.Status.LastSync = time.Now()

	if err := r.Client.Update(ctx, obj); err != nil {
		return err
	}

	return r.requeue(ctx, obj, 30*time.Second)
}
