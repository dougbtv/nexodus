package handlers

import (
	"context"
	"github.com/nexodus-io/nexodus/internal/database"

	"github.com/nexodus-io/nexodus/internal/util"

	"github.com/google/uuid"
	"github.com/nexodus-io/nexodus/internal/fflags"
	"github.com/nexodus-io/nexodus/internal/ipam"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"
	"gorm.io/gorm"
)

var tracer trace.Tracer

func init() {
	tracer = otel.Tracer("github.com/nexodus-io/nexodus/internal/handlers")
}

type API struct {
	logger        *zap.SugaredLogger
	db            *gorm.DB
	ipam          ipam.IPAM
	defaultZoneID uuid.UUID
	fflags        *fflags.FFlags
	transaction   database.TransactionFunc
}

func NewAPI(parent context.Context, logger *zap.SugaredLogger, db *gorm.DB, ipam ipam.IPAM, fflags *fflags.FFlags) (*API, error) {
	_, span := tracer.Start(parent, "NewAPI")
	defer span.End()

	transactionFunc, err := database.GetTransactionFunc(db)
	if err != nil {
		return nil, err
	}

	api := &API{
		logger:        logger,
		db:            db,
		ipam:          ipam,
		defaultZoneID: uuid.Nil,
		fflags:        fflags,
		transaction:   transactionFunc,
	}
	return api, nil
}

func (api *API) Logger(ctx context.Context) *zap.SugaredLogger {
	return util.WithTrace(ctx, api.logger)
}
