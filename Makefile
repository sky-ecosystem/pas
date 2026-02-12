PATH := ~/.solc-select/artifacts/solc-0.8.24:$(PATH)
certora-state        :; PATH=${PATH} certoraRun certora/BeamState.conf$(if $(rule), --rule $(rule),)$(if $(results), --wait_for_results all,)
certora-configurator :; PATH=${PATH} certoraRun certora/Configurator.conf$(if $(rule), --rule $(rule),)$(if $(results), --wait_for_results all,)
