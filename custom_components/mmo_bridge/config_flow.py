
from homeassistant import config_entries
from homeassistant.core import callback
from homeassistant.helpers.network import get_url, NoURLAvailableError
import voluptuous as vol

from . import DOMAIN


class MMOBridgeConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Config flow for MMO Bridge.

    No user input needed — the integration self-configures on submission.
    The webhook URL is available via the Configure button (options flow)
    once the integration is set up.
    """

    VERSION = 1

    async def async_step_user(self, user_input=None):
        if self._async_current_entries():
            return self.async_abort(reason="single_instance_allowed")
        if user_input is not None:
            return self.async_create_entry(title="MMO Bridge", data={})
        return self.async_show_form(step_id="user", data_schema=vol.Schema({}))

    async def async_step_import(self, import_data):
        """Auto-create an entry when the integration is configured via YAML."""
        if self._async_current_entries():
            return self.async_abort(reason="single_instance_allowed")
        return self.async_create_entry(title="MMO Bridge", data={})

    @staticmethod
    @callback
    def async_get_options_flow(config_entry):
        return MMOBridgeOptionsFlow()


class MMOBridgeOptionsFlow(config_entries.OptionsFlow):
    """Options flow — shows the webhook URL so users can copy it any time."""

    async def async_step_init(self, user_input=None):
        if user_input is not None:
            return self.async_create_entry(title="", data={})

        token = self.hass.data.get(DOMAIN, {}).get("token", "")
        try:
            base = get_url(self.hass, prefer_external=True)
        except NoURLAvailableError:
            base = ""

        path = f"/api/webhook/mmo_bridge?token={token}"
        webhook_url = f"{base}{path}" if base else path

        return self.async_show_form(
            step_id="init",
            data_schema=vol.Schema({}),
            description_placeholders={"webhook_url": webhook_url},
        )
