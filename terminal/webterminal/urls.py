from django.urls import path
from . import views

urlpatterns = [
    path('', views.index, name='webterminal_index'),
    path('gui/', views.gui, name='webterminal_gui'),
]
