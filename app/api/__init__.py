"""API router aggregation."""

from fastapi import APIRouter

from app.api import (
    auth,
    battles,
    body,
    canteens,
    integrations,
    meals,
    mealsets,
    mentorships,
    misc,
    workouts,
)

api_router = APIRouter()
api_router.include_router(auth.router)
api_router.include_router(canteens.router)
api_router.include_router(meals.router)
api_router.include_router(mealsets.router)
api_router.include_router(workouts.router)
api_router.include_router(body.router)
api_router.include_router(mentorships.router)
api_router.include_router(battles.router)
api_router.include_router(integrations.router)
api_router.include_router(misc.router)

__all__ = ["api_router"]
