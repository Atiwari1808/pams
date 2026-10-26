from django import forms

class LoginForm(forms.Form):
    username = forms.CharField(widget=forms.TextInput(attrs={'class': 'form-control', 'placeholder': 'Signum'}))
    password = forms.CharField(widget=forms.PasswordInput(attrs={'class': 'form-control', 'placeholder': 'Password'}))

# EXISTING LoginForm stays unchanged. ADD this below it:

from django.contrib.auth.models import User
from django.core.exceptions import ValidationError

class RegistrationForm(forms.Form):
    username  = forms.CharField(
        max_length=150,
        widget=forms.TextInput(attrs={
            'class': 'form-control',
            'placeholder': 'Choose a username'
        })
    )
    password1 = forms.CharField(
        label='Password',
        widget=forms.PasswordInput(attrs={
            'class': 'form-control',
            'placeholder': 'Create password'
        })
    )
    password2 = forms.CharField(
        label='Confirm Password',
        widget=forms.PasswordInput(attrs={
            'class': 'form-control',
            'placeholder': 'Repeat password'
        })
    )

    def clean_username(self):
        username = self.cleaned_data['username'].strip()
        if User.objects.filter(username=username).exists():
            raise ValidationError('This username is already taken.')
        return username

    def clean(self):
        cleaned = super().clean()
        p1 = cleaned.get('password1')
        p2 = cleaned.get('password2')
        if p1 and p2 and p1 != p2:
            raise ValidationError('Passwords do not match.')
        return cleaned
