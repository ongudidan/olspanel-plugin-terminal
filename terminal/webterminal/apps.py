from django.apps import AppConfig


class WebterminalConfig(AppConfig):
    name = 'modules.webterminal'
    verbose_name = 'Web Terminal'

    def ready(self):
        # Hook into WHM plugins list API view in-memory to dynamically register this custom plugin
        try:
            from whm import views as whm_views
            from django.http import JsonResponse
            import json

            # Store original function
            if not hasattr(whm_views, '_original_api_plugins'):
                whm_views._original_api_plugins = whm_views.api_plugins

            original_api_plugins = whm_views._original_api_plugins

            def patched_api_plugins(request):
                response = original_api_plugins(request)
                if isinstance(response, JsonResponse):
                    try:
                        data = json.loads(response.content.decode('utf-8'))
                        if data.get('success'):
                            plugins = data.get('plugins', [])
                            
                            # Check if already present by path or name
                            mod_path = "/usr/local/olspanel/mypanel/modules/webterminal"
                            existing_paths = {p.get('path') for p in plugins if p.get('path')}
                            existing_names = {p.get('name', '').lower() for p in plugins}

                            if mod_path not in existing_paths and "web terminal" not in existing_names:
                                terminal_cat_id = 3
                                for p in plugins:
                                    if p.get('category', '').lower() == 'terminal':
                                        terminal_cat_id = p.get('category_id', 3)
                                        break

                                web_terminal_plugin = {
                                    "id": 1000,
                                    "name": "Web Terminal<style>#pluginList > div { display: flex !important; flex-direction: column !important; height: 380px !important; } #pluginList > div > img { margin-top: auto !important; }</style>",
                                    "category": "Terminal",
                                    "category_id": terminal_cat_id,
                                    "type": "free",
                                    "url": "/module/webterminal/gui/",
                                    "path": mod_path,
                                    "image": "/media/icon/webterminal.svg",
                                    "pre_build_path": "",
                                    "is_installed": True,
                                    "license_valid": True
                                }
                                plugins.append(web_terminal_plugin)

                            data['plugins'] = plugins
                            data['count'] = len(plugins)
                            response.content = json.dumps(data).encode('utf-8')
                    except Exception:
                        pass
                return response

            whm_views.api_plugins = patched_api_plugins
            print("[WebTerminal] Successfully registered plugin auto-discovery hook.")
        except Exception as err:
            print(f"[WebTerminal] Dynamic registration warning: {err}")

